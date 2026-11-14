import sqlite3
from datetime import datetime, timedelta, timezone
from fpcore import autopublish as ap, fpdb, packing, constants as c
import numpy as np

NOW = datetime(2026, 11, 14, tzinfo=timezone.utc)


def _catalog(path, cards):
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE card(id TEXT, image_base TEXT, tcgplayer_id INTEGER, image_url TEXT)")
    conn.executemany("INSERT INTO card VALUES (?,?,?,?)", cards)
    conn.commit()
    conn.close()


def _pack(path, ids, fp_version=c.FP_VERSION, codebook="cb"):
    conn = fpdb.open_db(path)
    fpdb.write_meta(conn, codebook, "t", fp_version=fp_version)
    for cid in ids:
        fpdb.write_card_fp(conn, cid, b"", 1, packing.pack_keypoints(np.zeros((1, 2), np.float32)),
                           packing.pack_descriptors(np.zeros((1, 32), np.uint8)),
                           fp_version=fp_version)
    conn.close()


def test_missing_ids_only_counts_fingerprintable_and_current(tmp_path):
    cat, pack = str(tmp_path / "c.sqlite"), str(tmp_path / "p.sqlite")
    _catalog(cat, [("a", "http://x/a", None, None),     # in pack
                   ("b", "http://x/b", None, None),     # new, has art
                   ("c", None, None, None),             # no art at all: not fingerprintable
                   ("d", None, 12, None),               # tcgplayer art
                   ("e", "http://x/e", None, None)])    # in pack but at an old fp_version
    _pack(pack, ["a"])
    conn = sqlite3.connect(pack)
    conn.execute("INSERT INTO card_fp VALUES ('e', ?, x'', 1, x'', x'')", (c.FP_VERSION - 1,))
    conn.commit()
    conn.close()
    assert ap.missing_card_ids(cat, pack) == ["b", "d", "e"]


def test_ledger_tracks_first_seen_and_drops_resolved():
    led = ap.update_ledger({}, ["a", "b"], NOW)
    assert led["a"] == {"first_seen": NOW.isoformat(), "attempts": 0}
    led["a"]["attempts"] = 3
    later = NOW + timedelta(days=1)
    led2 = ap.update_ledger(led, ["a", "c"], later)
    assert led2["a"]["attempts"] == 3 and led2["a"]["first_seen"] == NOW.isoformat()
    assert led2["c"]["first_seen"] == later.isoformat() and "b" not in led2


def test_decide_debounce_and_threshold():
    led = ap.update_ledger({}, ["a"], NOW)
    assert ap.decide(led, NOW)[0] is False                                   # too fresh
    assert ap.decide(led, NOW + timedelta(days=1, hours=23))[0] is False
    go, _, ids = ap.decide(led, NOW + timedelta(days=2))
    assert go and ids == ["a"]                                               # any one card
    assert ap.decide({}, NOW)[:2] == (False, "pack is current")
    assert ap.decide(led, NOW, force=True)[0] is True                        # --force skips debounce


def test_decide_ignores_cards_out_of_attempts():
    led = ap.update_ledger({}, ["a", "b"], NOW)
    led["a"]["attempts"] = ap.MAX_ATTEMPTS
    later = NOW + timedelta(days=5)
    go, _, ids = ap.decide(led, later)
    assert go and ids == ["b"]
    led["b"]["attempts"] = ap.MAX_ATTEMPTS
    assert ap.decide(led, later)[0] is False
    assert ap.stuck_cards(led) == ["a", "b"]


def test_next_version_skips_v6_and_counts_stray_parts():
    # today: NAS serves v5, R2 v4, v6 parts still on disk -> v7
    assert ap.next_version(5, 4, {4, 5, 6}) == 7
    # even without the v6 part files, v6 is never reused
    assert ap.next_version(5, 4, {4, 5}) == 7
    assert ap.next_version(7, 7, {6, 7}) == 8
    assert ap.next_version(7, 6, {7, 9}) == 10          # a stray/half-published v9 is never reused
    assert ap.next_version(None, None, set()) == 7


def test_part_versions_and_prunable(tmp_path):
    for n in ["fingerprints-v5.part000", "fingerprints-v6.part000", "fingerprints-v4.part010",
              "manifest.json", "junk"]:
        (tmp_path / n).write_text("x")
    assert ap.part_versions(str(tmp_path)) == {4, 5, 6}
    # NAS serves v5, R2 still serves v4: v4 must NOT be pruned even though it is older
    assert ap.prunable_versions({4, 5, 6}, referenced={5, 4}, keep_previous=None) == [6]
    assert ap.prunable_versions({4, 5, 6, 7}, referenced={7}, keep_previous=5) == [4, 6]
    assert ap.part_versions(str(tmp_path / "missing")) == set()


def test_pack_meta_matches(tmp_path):
    p = str(tmp_path / "p.sqlite")
    _pack(p, ["a"], codebook="cb")
    assert ap.pack_meta_matches(p, "cb") == (True, "")
    ok, why = ap.pack_meta_matches(p, "other")
    assert not ok and "codebook" in why
    q = str(tmp_path / "q.sqlite")
    _pack(q, ["a"], fp_version=c.FP_VERSION + 1)
    assert not ap.pack_meta_matches(q, "cb")[0]


def test_state_roundtrip_and_defaults(tmp_path):
    p = str(tmp_path / "s" / "state.json")
    s = ap.load_state(p)
    assert s == {"ledger": {}, "published": []}
    s["published"].append({"version": 7})
    ap.save_state(p, s)
    assert ap.load_state(p)["published"] == [{"version": 7}]
    (tmp_path / "s" / "state.json").write_text("{not json")
    assert ap.load_state(p)["ledger"] == {}
