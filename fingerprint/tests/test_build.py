import sqlite3
import cv2
import numpy as np
from fpcore import build, codebook as cb, fpdb, packing


def _make_catalog(path):
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, image_base TEXT)")
    conn.executemany("INSERT INTO card(id, set_id, image_base) VALUES (?,?,?)", [
        ("card_a", "s1", "base/a"),
        ("card_b", "s1", "base/b"),
        ("card_null", "s1", None),  # skipped: null image_base
    ])
    conn.commit()
    conn.close()


def _fixture_loader():
    imgs = {
        "card_a": cv2.imread("tests/fixtures/card_a.png", cv2.IMREAD_COLOR),
        "card_b": cv2.imread("tests/fixtures/card_b.png", cv2.IMREAD_COLOR),
    }
    return lambda card_id, image_base: imgs.get(card_id)


def _codebook():
    from fpcore import canonicalize, descriptors as d
    cards = []
    for name in ("card_a", "card_b"):
        _, desc = d.extract(canonicalize.canonicalize(cv2.imread(f"tests/fixtures/{name}.png")))
        cards.append(desc)
    return cb.train(cards, K=32, seed=0, iters=5)


def test_build_writes_rows_and_meta(tmp_path):
    cat = str(tmp_path / "catalog.sqlite")
    out = str(tmp_path / "fingerprints.sqlite")
    _make_catalog(cat)
    book = _codebook()
    stats = build.build_fingerprints(cat, out, book, _fixture_loader(),
                                     built_at="2026-07-07T00:00:00Z")
    # card_null has NULL image_base -> filtered out by SQL, so it is neither built
    # nor "skipped" (skipped counts only fetch/extract failures inside the loop).
    assert stats == {"built": 2, "skipped": 0, "total": 2}
    conn = fpdb.open_db(out)
    assert fpdb.card_count(conn) == 2
    row = fpdb.read_card_fp(conn, "card_a")
    assert row["kp_count"] > 20
    assert len(row["descriptors"]) == row["kp_count"] * 32
    assert len(row["keypoints"]) == row["kp_count"] * 2 * 2      # n*2 float16
    assert row["global_vec"] == b""                              # global_vec is now empty
    meta = conn.execute("SELECT codebook_hash FROM meta").fetchone()
    assert meta[0] == book.sha256_hex()


def test_build_is_resumable(tmp_path):
    cat = str(tmp_path / "catalog.sqlite")
    out = str(tmp_path / "fingerprints.sqlite")
    _make_catalog(cat)
    book = _codebook()
    build.build_fingerprints(cat, out, book, _fixture_loader(), built_at="t")
    # second run with a loader that would fail if called -> all skipped as current
    def _boom(cid, ib):
        raise AssertionError("should not fetch already-current card")
    stats = build.build_fingerprints(cat, out, book, _boom, built_at="t")
    assert stats["built"] == 0


def test_per_card_size_within_budget(tmp_path):
    cat = str(tmp_path / "catalog.sqlite")
    out = str(tmp_path / "fingerprints.sqlite")
    _make_catalog(cat)
    book = _codebook()
    build.build_fingerprints(cat, out, book, _fixture_loader(), built_at="t")
    conn = fpdb.open_db(out)
    row = fpdb.read_card_fp(conn, "card_a")
    per_card = len(row["global_vec"]) + len(row["keypoints"]) + len(row["descriptors"])
    assert per_card <= 25_000  # ~24KB budget for keypoints + descriptors (global_vec now empty)


def test_stratified_sample_deterministic():
    rows = [(f"c{i}", f"base/{i}", "s1" if i < 6 else "s2") for i in range(10)]
    a = build.stratified_sample(rows, per_set=2, max_cards=10, seed=0)
    b = build.stratified_sample(rows, per_set=2, max_cards=10, seed=0)
    assert a == b
    assert len(a) == 4  # 2 per set x 2 sets
    assert all(len(t) == 2 for t in a)  # (card_id, image_base)
