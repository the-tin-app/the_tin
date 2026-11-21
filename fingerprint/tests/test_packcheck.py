import hashlib
import json
import os
import numpy as np
import pytest
from fpcore import constants as c, fpdb, packing, packcheck, publish

CB = "cb" * 32
PART = 64 * 1024


def _make_db(path, ids, codebook=CB, kp=40):
    conn = fpdb.open_db(path)
    fpdb.write_meta(conn, codebook, "2026-11-13T00:00:00Z")
    rng = np.random.default_rng(0)
    for cid in ids:
        xy = rng.uniform(0, 600, (kp, 2)).astype(np.float32)
        desc = rng.integers(0, 256, (kp, 32), dtype=np.uint8)
        fpdb.write_card_fp(conn, cid, b"", kp, packing.pack_keypoints(xy),
                           packing.pack_descriptors(desc))
    conn.close()


def _publish(tmp_path, db, version=7, codebook=CB, part_bytes=PART):
    out = tmp_path / "out"
    whole, total, parts = publish.split_into_parts(str(db), str(out), version, part_bytes=part_bytes)
    m = publish.make_parts_manifest(version, codebook, "2026-11-13T00:00:00Z", whole, total,
                                    parts, part_bytes=part_bytes)
    mp = out / "fingerprint" / "parts" / "manifest.json"
    mp.write_text(json.dumps(m))
    return out, mp, m


def _validate(out, mp, tmp_path, **kw):
    return packcheck.validate(str(out), str(mp), str(tmp_path / "scratch"),
                              expected_codebook_hash=kw.pop("cb", CB), **kw)


@pytest.fixture
def good(tmp_path):
    db = tmp_path / "pack.sqlite"
    _make_db(str(db), [f"c{i:04d}" for i in range(300)])
    assert os.path.getsize(db) > 3 * PART   # several parts
    return db


def test_good_pack_passes(tmp_path, good):
    out, mp, _ = _publish(tmp_path, good)
    r = _validate(out, mp, tmp_path)
    assert r.ok, r.failures
    assert r.info["cards"] == 300


def test_whole_sha_mismatch_is_caught(tmp_path, good):
    """The 2026-11-13 v6 symptom: every part's sha matches its file, whole sha does not."""
    out, mp, m = _publish(tmp_path, good)
    m["sha256"] = hashlib.sha256(b"something else").hexdigest()
    mp.write_text(json.dumps(m))
    r = _validate(out, mp, tmp_path)
    assert not r.ok and any("whole-sha" in f for f in r.failures)


def test_truncated_db_with_consistent_hashes_is_caught(tmp_path, good):
    """Hashes can be perfectly consistent and the database still garbage (the other half of v6)."""
    trunc = tmp_path / "trunc.sqlite"
    data = good.read_bytes()
    trunc.write_bytes(data[: len(data) // 2])
    out, mp, _ = _publish(tmp_path, trunc)
    r = _validate(out, mp, tmp_path)
    assert not r.ok and any(f.startswith("[integrity]") for f in r.failures)


def test_corrupt_part_bytes_caught(tmp_path, good):
    out, mp, m = _publish(tmp_path, good)
    p = out / m["parts"][1]["path"]
    b = bytearray(p.read_bytes())
    b[100] ^= 0xFF
    p.write_bytes(bytes(b))
    r = _validate(out, mp, tmp_path)
    assert not r.ok and any("sha256 mismatch" in f for f in r.failures)


def test_missing_part_and_wrong_size_caught(tmp_path, good):
    out, mp, m = _publish(tmp_path, good)
    (out / m["parts"][0]["path"]).unlink()
    assert any("missing" in f for f in _validate(out, mp, tmp_path).failures)
    (tmp_path / "o2").mkdir()
    out2, mp2, m2 = _publish(tmp_path / "o2", good)
    (out2 / m2["parts"][-1]["path"]).write_bytes(b"short")
    assert any("on disk" in f for f in _validate(out2, mp2, tmp_path).failures)


def test_manifest_sizes_inconsistent_caught(tmp_path, good):
    out, mp, m = _publish(tmp_path, good)
    m["sizeBytes"] += 1
    mp.write_text(json.dumps(m))
    assert any(f.startswith("[sizes]") for f in _validate(out, mp, tmp_path).failures)


def test_wrong_codebook_caught(tmp_path, good):
    out, mp, _ = _publish(tmp_path, good)
    r = _validate(out, mp, tmp_path, cb="ff" * 32)
    assert any("codebook_hash" in f for f in r.failures)


def test_manifest_meta_disagreement_caught(tmp_path, good):
    out, mp, m = _publish(tmp_path, good)
    m["codebookHash"] = "aa" * 32
    mp.write_text(json.dumps(m))
    assert any("codebook_hash" in f for f in _validate(out, mp, tmp_path, cb=None).failures)


def test_unreadable_manifest_is_a_failure_not_a_crash(tmp_path):
    r = packcheck.validate(str(tmp_path), str(tmp_path / "nope.json"), str(tmp_path / "s"))
    assert not r.ok


def test_no_regression_gate(tmp_path, good):
    live = tmp_path / "live.sqlite"
    _make_db(str(live), [f"c{i:04d}" for i in range(250)])
    out, mp, m = _publish(tmp_path, good)          # superset of live: fine
    r = _validate(out, mp, tmp_path, live_db_path=str(live), live_size=os.path.getsize(live))
    assert r.ok, r.failures
    assert r.info["added"] == 50

    smaller = tmp_path / "smaller.sqlite"
    _make_db(str(smaller), [f"c{i:04d}" for i in range(100, 300)])   # drops c0000-c0099
    (tmp_path / "o3").mkdir()
    out2, mp2, _ = _publish(tmp_path / "o3", smaller)
    r2 = _validate(out2, mp2, tmp_path, live_db_path=str(good), live_size=os.path.getsize(good))
    assert any("missing from the new" in f for f in r2.failures)
