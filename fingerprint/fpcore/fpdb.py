"""Reader/writer for fingerprints.sqlite (the shipped pack). Schema is the
master-spec schema; global_vec/keypoints/descriptors are packed by fpcore.packing."""
import sqlite3
from . import constants as c

_SCHEMA = """
CREATE TABLE IF NOT EXISTS card_fp(
  card_id     TEXT PRIMARY KEY,
  fp_version  INTEGER,
  global_vec  BLOB,
  kp_count    INTEGER,
  keypoints   BLOB,
  descriptors BLOB
);
CREATE TABLE IF NOT EXISTS meta(
  fp_version    INTEGER,
  codebook_hash TEXT,
  canonical_w   INTEGER,
  canonical_h   INTEGER,
  built_at      TEXT
);
"""


def open_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.executescript(_SCHEMA)
    conn.commit()
    return conn


def write_meta(conn, codebook_hash: str, built_at: str,
               fp_version: int = c.FP_VERSION, canon_w: int = c.CANON_W,
               canon_h: int = c.CANON_H) -> None:
    conn.execute("DELETE FROM meta")
    conn.execute(
        "INSERT INTO meta(fp_version, codebook_hash, canonical_w, canonical_h, built_at)"
        " VALUES (?,?,?,?,?)",
        (fp_version, codebook_hash, canon_w, canon_h, built_at))
    conn.commit()


def write_card_fp(conn, card_id: str, global_vec: bytes, kp_count: int,
                  keypoints: bytes, descriptors: bytes,
                  fp_version: int = c.FP_VERSION) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO card_fp"
        "(card_id, fp_version, global_vec, kp_count, keypoints, descriptors)"
        " VALUES (?,?,?,?,?,?)",
        (card_id, fp_version, sqlite3.Binary(global_vec), kp_count,
         sqlite3.Binary(keypoints), sqlite3.Binary(descriptors)))
    conn.commit()


def read_card_fp(conn, card_id: str):
    cur = conn.execute(
        "SELECT card_id, fp_version, global_vec, kp_count, keypoints, descriptors"
        " FROM card_fp WHERE card_id=?", (card_id,))
    r = cur.fetchone()
    if r is None:
        return None
    return {"card_id": r[0], "fp_version": r[1], "global_vec": bytes(r[2]),
            "kp_count": r[3], "keypoints": bytes(r[4]), "descriptors": bytes(r[5])}


def has_current(conn, card_id: str, fp_version: int = c.FP_VERSION) -> bool:
    cur = conn.execute(
        "SELECT 1 FROM card_fp WHERE card_id=? AND fp_version=?", (card_id, fp_version))
    return cur.fetchone() is not None


def card_count(conn) -> int:
    return conn.execute("SELECT COUNT(*) FROM card_fp").fetchone()[0]
