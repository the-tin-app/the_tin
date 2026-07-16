from fpcore import fpdb, constants as c

def test_schema_and_card_roundtrip(tmp_path):
    conn = fpdb.open_db(str(tmp_path / "fp.sqlite"))
    fpdb.write_card_fp(conn, "swsh7-215", b"\x01\x02", 1, b"\x03\x04", b"\x05" * 32)
    row = fpdb.read_card_fp(conn, "swsh7-215")
    assert row["card_id"] == "swsh7-215"
    assert row["fp_version"] == c.FP_VERSION
    assert row["kp_count"] == 1
    assert row["global_vec"] == b"\x01\x02"
    assert row["keypoints"] == b"\x03\x04"
    assert row["descriptors"] == b"\x05" * 32

def test_meta_roundtrip(tmp_path):
    conn = fpdb.open_db(str(tmp_path / "fp.sqlite"))
    fpdb.write_meta(conn, "abc123", "2026-07-07T00:00:00Z")
    cur = conn.execute("SELECT fp_version, codebook_hash, canonical_w, canonical_h, built_at FROM meta")
    fp_version, codebook_hash, w, h, built = cur.fetchone()
    assert (fp_version, codebook_hash, w, h, built) == (
        c.FP_VERSION, "abc123", c.CANON_W, c.CANON_H, "2026-07-07T00:00:00Z")

def test_has_current_and_count(tmp_path):
    conn = fpdb.open_db(str(tmp_path / "fp.sqlite"))
    assert fpdb.card_count(conn) == 0
    assert not fpdb.has_current(conn, "x")
    fpdb.write_card_fp(conn, "x", b"", 0, b"", b"")
    assert fpdb.has_current(conn, "x")
    assert fpdb.card_count(conn) == 1

def test_read_missing_returns_none(tmp_path):
    conn = fpdb.open_db(str(tmp_path / "fp.sqlite"))
    assert fpdb.read_card_fp(conn, "nope") is None
