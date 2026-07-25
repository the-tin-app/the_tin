import hashlib
import gzip
import os
import pytest
from fpcore import publish, constants as c


def test_gzip_is_deterministic_and_valid():
    data = b"hello fingerprint" * 100
    g1 = publish.gzip_bytes(data)
    g2 = publish.gzip_bytes(data)
    assert g1 == g2                       # reproducible (mtime=0)
    assert gzip.decompress(g1) == data


def test_manifest_shape_matches_catalog_convention():
    gz = publish.gzip_bytes(b"sqlite-bytes")
    m = publish.make_manifest(gz, version=3, codebook_hash="cbhash",
                              generated_at="2026-07-07T00:00:00Z")
    # catalog-parallel fields
    assert m["version"] == 3
    assert m["path"] == "fingerprint/fingerprints-v3.sqlite.gz"
    assert m["sha256"] == hashlib.sha256(gz).hexdigest()  # sha256 of GZIPPED bytes
    assert m["sizeBytes"] == len(gz)
    assert m["generatedAt"] == "2026-07-07T00:00:00Z"
    # fingerprint-specific gate fields
    assert m["fpVersion"] == c.FP_VERSION
    assert m["codebookHash"] == "cbhash"
    assert m["canonicalW"] == c.CANON_W
    assert m["canonicalH"] == c.CANON_H


# --- parts format -------------------------------------------------------------------


def _write_pack(tmp_path, data: bytes) -> str:
    db = tmp_path / "fingerprints.sqlite"
    db.write_bytes(data)
    return str(db)


def test_parts_concatenate_back_to_the_original_pack(tmp_path):
    """The whole contract in one assertion: parts are a plain byte split, so the client
    can write each at index*partSize and never assemble."""
    data = bytes(range(256)) * 40          # 10,240 B -> 4 parts of 3,000 + a 1,240 B tail
    db = _write_pack(tmp_path, data)
    out = str(tmp_path / "out")

    whole_sha, total, parts = publish.split_into_parts(db, out, version=4, part_bytes=3000)

    assert total == len(data)
    assert whole_sha == hashlib.sha256(data).hexdigest()
    assert len(parts) == 4
    rejoined = b"".join(open(os.path.join(out, p["path"]), "rb").read() for p in parts)
    assert rejoined == data


def test_part_entries_describe_each_file_exactly(tmp_path):
    data = b"\x00\xff" * 2500              # 5,000 B -> 2 parts of 3,000 + 2,000
    db = _write_pack(tmp_path, data)
    out = str(tmp_path / "out")

    _, _, parts = publish.split_into_parts(db, out, version=7, part_bytes=3000)

    assert [p["bytes"] for p in parts] == [3000, 2000]
    assert [p["path"] for p in parts] == [
        "fingerprint/parts/fingerprints-v7.part000",
        "fingerprint/parts/fingerprints-v7.part001",
    ]
    for p in parts:
        raw = open(os.path.join(out, p["path"]), "rb").read()
        assert len(raw) == p["bytes"]
        assert hashlib.sha256(raw).hexdigest() == p["sha256"]   # per-part gate, refetch one


def test_exact_multiple_of_part_size_emits_no_empty_tail(tmp_path):
    db = _write_pack(tmp_path, b"z" * 6000)
    _, _, parts = publish.split_into_parts(db, str(tmp_path / "out"), version=4, part_bytes=3000)
    assert [p["bytes"] for p in parts] == [3000, 3000]


def test_empty_pack_is_rejected(tmp_path):
    db = _write_pack(tmp_path, b"")
    with pytest.raises(ValueError):
        publish.split_into_parts(db, str(tmp_path / "out"), version=4)


def test_parts_manifest_keeps_the_legacy_compatibility_gates(tmp_path):
    """The client's version/fpVersion/codebookHash gates must read identically across
    formats — only sha256/sizeBytes change meaning (assembled sqlite, not gzipped bytes)."""
    data = b"sqlite-bytes" * 500
    db = _write_pack(tmp_path, data)
    whole_sha, total, parts = publish.split_into_parts(
        db, str(tmp_path / "out"), version=4, part_bytes=1000)

    m = publish.make_parts_manifest(4, "cbhash", "2026-07-24T00:00:00Z",
                                    whole_sha, total, parts, part_bytes=1000)

    assert m["version"] == 4
    assert m["fpVersion"] == c.FP_VERSION
    assert m["codebookHash"] == "cbhash"
    assert m["canonicalW"] == c.CANON_W
    assert m["canonicalH"] == c.CANON_H
    assert m["generatedAt"] == "2026-07-24T00:00:00Z"
    # parts-specific: sha256/sizeBytes describe the UNCOMPRESSED assembled pack
    assert m["format"] == "parts"
    assert m["partSize"] == 1000
    assert m["sha256"] == hashlib.sha256(data).hexdigest()
    assert m["sizeBytes"] == len(data)
    assert sum(p["bytes"] for p in m["parts"]) == m["sizeBytes"]


def test_descriptor_payload_does_not_compress(tmp_path):
    """Rationale guard for dropping gzip: the pack is ~all high-entropy ORB descriptors.
    If a future format change ever makes the payload compressible, this fails and the
    no-compression decision deserves revisiting."""
    fixture = os.path.join(os.path.dirname(__file__), "..", "..", "ios", "TheTin",
                           "Tests", "Fixtures", "Fingerprint", "fingerprints-fixture.sqlite")
    if not os.path.exists(fixture):
        pytest.skip("ios fingerprint fixture not present")
    import sqlite3
    conn = sqlite3.connect(fixture)
    blobs = b"".join(r[0] for r in conn.execute("SELECT descriptors FROM card_fp"))
    conn.close()
    if not blobs:
        pytest.skip("fixture carries no descriptor blobs")
    assert len(gzip.compress(blobs, 9)) >= len(blobs) * 0.98
