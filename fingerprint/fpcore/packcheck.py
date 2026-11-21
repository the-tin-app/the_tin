"""Validation gates for a published fingerprint pack (parts format).

Used before a pack is shipped (staging), after it is copied (the files as they sit on the
origin), and by the daily drift check. The first five gates mirror what the iOS client does in
`FingerprintUpdater.install(parts:)` — per-part size/sha256, then the whole-file sha256 gate
before install — and the rest catch what the client cannot: a pack that hashes consistently but
is not a usable database (the 2026-11-13 v6 incident: whole sha did not match the parts, and the
parts concatenated to a malformed, truncated sqlite).

Nothing here talks to the network or writes outside `workdir`.
"""
import hashlib
import json
import math
import os
import re
import sqlite3
from dataclasses import dataclass, field
from . import constants as c, packing

_PART_RE = re.compile(r"^fingerprint/parts/fingerprints-v(\d+)\.part(\d{3})$")
_REQUIRED = ("version", "format", "partSize", "parts", "sha256", "sizeBytes",
             "fpVersion", "codebookHash", "canonicalW", "canonicalH")


@dataclass
class Report:
    failures: list = field(default_factory=list)
    info: dict = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return not self.failures

    def fail(self, gate: str, msg: str):
        self.failures.append(f"[{gate}] {msg}")


def load_manifest(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def _sha_file(path: str, bufsize: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(bufsize):
            h.update(chunk)
    return h.hexdigest()


def check_manifest_and_parts(base: str, manifest: dict, report: Report):
    """Gates 1-3. `base` is the directory that manifest paths are relative to
    (`<base>/fingerprint/parts/...`): the staging out dir, or the NAS data root."""
    missing = [k for k in _REQUIRED if k not in manifest]
    if missing:
        report.fail("manifest", f"missing fields {missing}")
        return
    if manifest["format"] != "parts":
        report.fail("manifest", f"format is {manifest['format']!r}, expected 'parts'")
        return
    parts, part_size = manifest["parts"], manifest["partSize"]
    if not parts:
        report.fail("manifest", "no parts listed")
        return

    expect_parts = math.ceil(manifest["sizeBytes"] / part_size)
    if len(parts) != expect_parts:
        report.fail("sizes", f"{len(parts)} parts listed but sizeBytes={manifest['sizeBytes']} "
                             f"at partSize={part_size} needs {expect_parts}")
    if sum(p["bytes"] for p in parts) != manifest["sizeBytes"]:
        report.fail("sizes", f"parts sum to {sum(p['bytes'] for p in parts)}, "
                             f"manifest sizeBytes={manifest['sizeBytes']}")

    whole = hashlib.sha256()
    for i, p in enumerate(parts):
        m = _PART_RE.match(p["path"])
        if not m or int(m.group(1)) != manifest["version"] or int(m.group(2)) != i:
            report.fail("parts", f"part {i} path {p['path']!r} is not "
                                 f"fingerprints-v{manifest['version']}.part{i:03d}")
            continue
        if i < len(parts) - 1 and p["bytes"] != part_size:
            report.fail("sizes", f"part {i} is {p['bytes']} B, only the last may be short")
        path = os.path.join(base, p["path"])
        try:
            actual = os.path.getsize(path)
        except OSError:
            report.fail("parts", f"{p['path']} missing under {base}")
            continue
        if actual != p["bytes"]:
            report.fail("parts", f"{p['path']} is {actual} B on disk, manifest says {p['bytes']}")
            continue
        h = hashlib.sha256()
        with open(path, "rb") as f:
            while chunk := f.read(1 << 20):
                h.update(chunk)
                whole.update(chunk)
        if h.hexdigest() != p["sha256"].lower():
            report.fail("parts", f"{p['path']} sha256 mismatch")

    if not report.failures:
        # The gate the client enforces after the last part lands (FingerprintUpdater.swift:262).
        if whole.hexdigest() != manifest["sha256"].lower():
            report.fail("whole-sha", f"concatenated parts hash to {whole.hexdigest()}, "
                                     f"manifest sha256 is {manifest['sha256']}")


def assemble(base: str, manifest: dict, dest: str) -> str:
    """Concatenate the parts into `dest` (streaming). Caller has already validated them."""
    with open(dest, "wb") as out:
        for p in manifest["parts"]:
            with open(os.path.join(base, p["path"]), "rb") as f:
                while chunk := f.read(1 << 20):
                    out.write(chunk)
    return dest


def check_database(db_path: str, manifest: dict, expected_codebook_hash: str | None,
                   report: Report, sample: int = 200):
    """Gates 4-5 and the decode smoke: integrity, meta == constants == manifest, rows decode."""
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        res = conn.execute("PRAGMA integrity_check").fetchall()
    except sqlite3.DatabaseError as e:
        report.fail("integrity", f"not a readable sqlite: {e}")
        return
    if res != [("ok",)]:
        report.fail("integrity", f"integrity_check: {res[0][0]} (+{len(res) - 1} more)")
        return
    try:
        meta = conn.execute("SELECT fp_version, codebook_hash, canonical_w, canonical_h, "
                            "built_at FROM meta").fetchall()
    except sqlite3.DatabaseError as e:
        report.fail("meta", f"cannot read meta: {e}")
        return
    if len(meta) != 1:
        report.fail("meta", f"{len(meta)} meta rows, expected 1")
        return
    fp_version, cb_hash, cw, ch, built_at = meta[0]
    report.info.update(fp_version=fp_version, codebook_hash=cb_hash, built_at=built_at)
    if fp_version != c.FP_VERSION or fp_version != manifest["fpVersion"]:
        report.fail("meta", f"fp_version db={fp_version} constants={c.FP_VERSION} "
                            f"manifest={manifest['fpVersion']}")
    if (cw, ch) != (c.CANON_W, c.CANON_H) or (cw, ch) != (manifest["canonicalW"], manifest["canonicalH"]):
        report.fail("meta", f"canonical size db={(cw, ch)} manifest="
                            f"{(manifest['canonicalW'], manifest['canonicalH'])}")
    if cb_hash != manifest["codebookHash"]:
        report.fail("meta", f"codebook_hash db={cb_hash} manifest={manifest['codebookHash']}")
    if expected_codebook_hash and cb_hash != expected_codebook_hash:
        report.fail("meta", f"codebook_hash {cb_hash} != committed codebook {expected_codebook_hash}")

    n = conn.execute("SELECT COUNT(*) FROM card_fp").fetchone()[0]
    report.info["cards"] = n
    if n == 0:
        report.fail("cards", "card_fp is empty")
        return
    stale = conn.execute("SELECT COUNT(*) FROM card_fp WHERE fp_version<>?",
                         (c.FP_VERSION,)).fetchone()[0]
    if stale:
        report.fail("cards", f"{stale} rows are not at fp_version {c.FP_VERSION}")
    # Decode smoke: a deterministic spread of rows must unpack to the sizes the client expects.
    rows = conn.execute("SELECT card_id, kp_count, keypoints, descriptors FROM card_fp "
                        "ORDER BY card_id LIMIT ? OFFSET ?", (sample, 0)).fetchall()
    step = max(1, n // sample)
    rows += conn.execute("SELECT card_id, kp_count, keypoints, descriptors FROM card_fp "
                         "WHERE rowid % ? = 0 LIMIT ?", (step, sample)).fetchall()
    for card_id, kp_count, kps, desc in rows:
        if kp_count <= 0:
            report.fail("decode", f"{card_id}: kp_count={kp_count}")
            break
        try:
            packing.unpack_keypoints(bytes(kps), kp_count)
            packing.unpack_descriptors(bytes(desc), kp_count)
        except Exception as e:  # noqa: BLE001 — any decode failure is a hard fail
            report.fail("decode", f"{card_id}: {e}")
            break
    conn.close()


def check_no_regression(db_path: str, live_db_path: str, report: Report,
                        live_size: int | None = None, new_size: int | None = None):
    """Gate 6/8: never publish a pack that lost cards or shrank versus the one being replaced."""
    new = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    live = sqlite3.connect(f"file:{live_db_path}?mode=ro", uri=True)
    live_ids = {r[0] for r in live.execute("SELECT card_id FROM card_fp")}
    new_ids = {r[0] for r in new.execute("SELECT card_id FROM card_fp")}
    gone = live_ids - new_ids
    report.info.update(live_cards=len(live_ids), new_cards=len(new_ids), added=len(new_ids - live_ids))
    if gone:
        report.fail("regression", f"{len(gone)} cards in the live pack are missing from the new "
                                  f"one (e.g. {sorted(gone)[:3]})")
    if live_size is not None and new_size is not None:
        if new_size < live_size:
            report.fail("regression", f"new pack {new_size} B is smaller than live {live_size} B")
        elif new_size > live_size * 1.5:
            report.fail("regression", f"new pack {new_size} B is more than 1.5x live {live_size} B")
    new.close()
    live.close()


def validate(base: str, manifest_path: str, workdir: str,
             expected_codebook_hash: str | None = None,
             live_db_path: str | None = None, live_size: int | None = None) -> Report:
    """Run every gate against the manifest + parts under `base`. Never raises on a bad pack:
    returns a Report whose `failures` say which gate failed."""
    report = Report()
    try:
        manifest = load_manifest(manifest_path)
    except (OSError, ValueError) as e:
        report.fail("manifest", f"cannot read {manifest_path}: {e}")
        return report
    report.info["version"] = manifest.get("version")
    check_manifest_and_parts(base, manifest, report)
    if not report.ok:
        return report
    os.makedirs(workdir, exist_ok=True)
    db = os.path.join(workdir, f"validate-v{manifest['version']}.sqlite")
    try:
        assemble(base, manifest, db)
        check_database(db, manifest, expected_codebook_hash, report)
        if report.ok and live_db_path:
            check_no_regression(db, live_db_path, report, live_size, manifest["sizeBytes"])
    finally:
        if os.path.exists(db):
            os.remove(db)
    return report
