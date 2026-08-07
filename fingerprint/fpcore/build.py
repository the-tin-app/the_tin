"""Catalog-wide fingerprint build. Network-free: the caller injects
load_image(card_id, image_url) -> bgr|None. Resumable: rows already at the
current fp_version are skipped unless force=True."""
import time
import numpy as np
import sqlite3
from . import canonicalize, descriptors as d, packing, fpdb, constants as c

# The art URL for a card, in the SAME precedence the app uses (CardRecord.imageURL):
# tcgdex asset base, else the public TCGplayer CDN derived from the product id, else a
# legacy stored URL. Selecting on `image_base` alone — which every query here used to do —
# meant the scanner could not see 1,416 cards the app displays perfectly well, including
# every MEP promo and all 120 of me05 Pitch Black.
#
# Keep this in step with `CardRecord.imageURL(quality:)` in CatalogModels.swift; a card the
# app can show but the pack has no fingerprint for is a card that fails to scan.
IMAGE_URL_SQL = """COALESCE(
  CASE WHEN image_base   IS NOT NULL AND image_base   <> '' THEN image_base || '/high.webp' END,
  CASE WHEN tcgplayer_id IS NOT NULL THEN 'https://tcgplayer-cdn.tcgplayer.com/product/' || tcgplayer_id || '_in_1000x1000.jpg' END,
  CASE WHEN image_url    IS NOT NULL AND image_url    <> '' THEN image_url END
)"""
# Cards we can fingerprint at all. Every caller must use this, or the pack and the eval
# harnesses disagree about which cards exist.
FINGERPRINTABLE_WHERE = f"{IMAGE_URL_SQL} IS NOT NULL"


def stratified_sample(rows, per_set: int, max_cards: int, seed: int):
    """rows: list of (card_id, image_url, set_id). Deterministic sample of up to
    per_set cards per set, capped at max_cards, ordered by set then original order."""
    rng = np.random.default_rng(seed)
    by_set = {}
    for card_id, image_url, set_id in rows:
        by_set.setdefault(set_id, []).append((card_id, image_url))
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
        f"SELECT id, {IMAGE_URL_SQL} FROM card WHERE {FINGERPRINTABLE_WHERE}"
    ).fetchall()
    cat.close()

    conn = fpdb.open_db(out_path)
    fpdb.write_meta(conn, codebook.sha256_hex(), built_at, fp_version=fp_version)

    built = skipped = 0
    for card_id, image_url in rows:
        if not force and fpdb.has_current(conn, card_id, fp_version):
            continue
        bgr = load_image(card_id, image_url)
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
        global_vec = packing.pack_global_vec(codebook.global_vec(desc))
        fpdb.write_card_fp(
            conn, card_id,
            global_vec,
            len(kps),
            packing.pack_keypoints(xy),
            packing.pack_descriptors(desc),
            fp_version=fp_version)
        built += 1
        if on_progress:
            on_progress(card_id, built, skipped)
    conn.commit()
    return {"built": built, "skipped": skipped, "total": len(rows)}
