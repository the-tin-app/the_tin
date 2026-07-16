"""Catalog-wide fingerprint build. Network-free: the caller injects
load_image(card_id, image_base) -> bgr|None. Resumable: rows already at the
current fp_version are skipped unless force=True."""
import time
import numpy as np
import sqlite3
from . import canonicalize, descriptors as d, packing, fpdb, constants as c


def stratified_sample(rows, per_set: int, max_cards: int, seed: int):
    """rows: list of (card_id, image_base, set_id). Deterministic sample of up to
    per_set cards per set, capped at max_cards, ordered by set then original order."""
    rng = np.random.default_rng(seed)
    by_set = {}
    for card_id, image_base, set_id in rows:
        by_set.setdefault(set_id, []).append((card_id, image_base))
    picked = []
    for set_id in sorted(by_set):
        members = by_set[set_id]
        if len(members) <= per_set:
            chosen_idx = range(len(members))
        else:
            chosen_idx = sorted(rng.choice(len(members), size=per_set, replace=False).tolist())
        picked.extend(members[i] for i in chosen_idx)
    return picked[:max_cards]


def build_fingerprints(catalog_path: str, out_path: str, codebook, load_image,
                       built_at: str, fp_version: int = c.FP_VERSION,
                       force: bool = False, throttle: float | None = None,
                       on_progress=None) -> dict:
    cat = sqlite3.connect(catalog_path)
    rows = cat.execute(
        "SELECT id, image_base FROM card WHERE image_base IS NOT NULL"
    ).fetchall()
    cat.close()

    conn = fpdb.open_db(out_path)
    fpdb.write_meta(conn, codebook.sha256_hex(), built_at, fp_version=fp_version)

    built = skipped = 0
    for card_id, image_base in rows:
        if not force and fpdb.has_current(conn, card_id, fp_version):
            continue
        bgr = load_image(card_id, image_base)
        if throttle:
            time.sleep(throttle)
        if bgr is None:
            skipped += 1
            continue
        kps, desc = d.extract(canonicalize.canonicalize(bgr))
        if len(kps) == 0:
            skipped += 1
            continue
        xy = np.array([[k.x, k.y] for k in kps], dtype=np.float32)
        fpdb.write_card_fp(
            conn, card_id,
            b"",
            len(kps),
            packing.pack_keypoints(xy),
            packing.pack_descriptors(desc),
            fp_version=fp_version)
        built += 1
        if on_progress:
            on_progress(card_id, built, skipped)
    conn.commit()
    return {"built": built, "skipped": skipped, "total": len(rows)}
