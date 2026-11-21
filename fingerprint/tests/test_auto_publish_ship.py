"""Ship / rollback / prune paths of scripts/auto_publish.py against an in-memory fake S3."""
import importlib.util
import json
import os
import types
from datetime import timedelta
from pathlib import Path
import pytest
from fpcore import autopublish as ap, publish

SPEC = importlib.util.spec_from_file_location(
    "auto_publish", os.path.join(os.path.dirname(__file__), "..", "scripts", "auto_publish.py"))
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)

CB = "cb" * 32
PART = 1024


class FakeS3:
    def __init__(self):
        self.objects, self.fail_put_on, self.puts = {}, None, []

    def get_object(self, Bucket, Key):
        if Key not in self.objects:
            raise KeyError(Key)
        return {"Body": types.SimpleNamespace(read=lambda: self.objects[Key])}

    def upload_file(self, path, Bucket, Key):
        if self.fail_put_on and self.fail_put_on in Key:
            raise OSError("simulated R2 outage")
        self.puts.append(Key)
        self.objects[Key] = open(path, "rb").read()

    def delete_object(self, Bucket, Key):
        self.objects.pop(Key, None)

    def get_paginator(self, _):
        outer = self
        class P:
            def paginate(self, Bucket, Prefix):
                yield {"Contents": [{"Key": k} for k in outer.objects if k.startswith(Prefix)]}
        return P()


def _pack(root, version, payload):
    """Write a valid-by-hashes parts set (not a real sqlite) under root; return manifest."""
    root.mkdir(parents=True, exist_ok=True)
    db = root / f"p{version}.bin"
    db.write_bytes(payload)
    whole, total, parts = publish.split_into_parts(str(db), str(root / "out"), version, part_bytes=PART)
    m = publish.make_parts_manifest(version, CB, "t", whole, total, parts, part_bytes=PART)
    (root / "out" / "fingerprint" / "parts" / "manifest.json").write_text(json.dumps(m))
    return m, str(root / "out")


@pytest.fixture
def env(tmp_path, monkeypatch):
    fake = FakeS3()
    monkeypatch.setattr(mod, "_r2_client", fake)
    # The real validator needs a sqlite; hash-level gates are covered in test_packcheck.
    monkeypatch.setattr(mod.packcheck, "validate",
                        lambda base, mp, wd, **kw: _hash_only(base, mp))
    nas = tmp_path / "nas"
    (nas / "fingerprint" / "parts").mkdir(parents=True)
    old, _ = _pack(tmp_path / "old", 5, b"o" * 3000)
    old_raw = json.dumps(old).encode()
    (nas / "fingerprint" / "parts" / "manifest.json").write_bytes(old_raw)
    fake.objects["fingerprint/parts/manifest.json"] = old_raw
    new, stage = _pack(tmp_path / "new", 7, b"n" * 5000)
    args = types.SimpleNamespace(data_root=str(nas), work=str(tmp_path / "work"))
    os.makedirs(args.work)
    return types.SimpleNamespace(fake=fake, nas=nas, old_raw=old_raw, new=new, stage=stage,
                                 args=args, state={"ledger": {}, "published": []})


def _hash_only(base, mp):
    from fpcore import packcheck
    rep = packcheck.Report()
    packcheck.check_manifest_and_parts(base, packcheck.load_manifest(mp), rep)
    return rep


def _nas_version(env):
    return json.load(open(env.nas / "fingerprint" / "parts" / "manifest.json"))["version"]


def test_ship_success_flips_both_origins_manifest_last(env):
    mod.ship(env.args, env.new, env.stage, env.state)
    assert _nas_version(env) == 7
    assert json.loads(env.fake.objects["fingerprint/parts/manifest.json"])["version"] == 7
    assert env.fake.puts[-1] == "fingerprint/parts/manifest.json"            # manifest LAST on R2
    assert all(p["path"] in env.fake.objects for p in env.new["parts"])
    for p in env.new["parts"]:
        assert (env.nas / p["path"]).exists()


def test_r2_part_upload_failure_leaves_both_origins_untouched(env):
    env.fake.fail_put_on = "part001"
    with pytest.raises(RuntimeError):
        mod.ship(env.args, env.new, env.stage, env.state)
    assert _nas_version(env) == 5
    assert env.fake.objects["fingerprint/parts/manifest.json"] == env.old_raw


def test_nas_flip_failure_rolls_r2_manifest_back(env, monkeypatch):
    real = mod.write_manifest_atomic
    calls = []
    def flaky(path, raw):
        calls.append(path)
        if len(calls) == 1:
            raise OSError("NFS went away")
        return real(path, raw)
    monkeypatch.setattr(mod, "write_manifest_atomic", flaky)
    with pytest.raises(OSError):
        mod.ship(env.args, env.new, env.stage, env.state)
    assert env.fake.objects["fingerprint/parts/manifest.json"] == env.old_raw   # R2 restored
    assert _nas_version(env) == 5


def test_corrupt_nas_copy_is_caught_before_r2_is_touched(env, monkeypatch):
    def corrupting_copy(src, dest):
        open(dest, "wb").write(b"garbage")
    monkeypatch.setattr(mod, "atomic_copy", corrupting_copy)
    with pytest.raises(RuntimeError, match="NAS copy failed validation"):
        mod.ship(env.args, env.new, env.stage, env.state)
    assert env.fake.puts == []
    assert _nas_version(env) == 5


def test_r2_manifest_read_failure_returns_none(env):
    del env.fake.objects["fingerprint/parts/manifest.json"]
    assert mod.r2_get_manifest() == (None, None)


def test_prune_respects_both_origins_and_24h_rule(env):
    mod.ship(env.args, env.new, env.stage, env.state)           # both origins now at v7
    for v in (3, 4):                                            # stale R2 versions
        env.fake.objects[f"fingerprint/parts/fingerprints-v{v}.part000"] = b"x"
    (env.nas / "fingerprint" / "parts" / "fingerprints-v6.part000").write_bytes(b"bad")
    now = ap.now_utc()
    env.state["published"] = [{"version": 5, "at": (now - timedelta(days=3)).isoformat()},
                              {"version": 7, "at": (now - timedelta(hours=2)).isoformat()}]
    mod.prune(env.args, env.state)                              # v7 only 2 h old: nothing pruned
    assert "fingerprint/parts/fingerprints-v3.part000" in env.fake.objects
    env.state["published"][-1]["at"] = (now - timedelta(hours=30)).isoformat()
    mod.prune(env.args, env.state)
    keys = set(env.fake.objects)
    assert "fingerprint/parts/fingerprints-v3.part000" not in keys
    assert "fingerprint/parts/fingerprints-v4.part000" not in keys
    assert all(p["path"] in keys for p in env.new["parts"])     # live v7 kept
    assert not (env.nas / "fingerprint" / "parts" / "fingerprints-v6.part000").exists()


def test_prune_never_deletes_a_version_the_lagging_origin_still_serves(env):
    # NAS at v7, R2 still serving v4: v4 must survive even though it is old and unreferenced by NAS
    mod.ship(env.args, env.new, env.stage, env.state)
    old4, _ = _pack(Path(env.args.work) / "v4", 4, b"4" * 2500)
    for p in old4["parts"]:
        env.fake.objects[p["path"]] = b"x"
    env.fake.objects["fingerprint/parts/manifest.json"] = json.dumps(old4).encode()
    now = ap.now_utc()
    env.state["published"] = [{"version": 5, "at": (now - timedelta(days=5)).isoformat()},
                              {"version": 7, "at": (now - timedelta(days=2)).isoformat()}]
    mod.prune(env.args, env.state)
    assert all(p["path"] in env.fake.objects for p in old4["parts"])
