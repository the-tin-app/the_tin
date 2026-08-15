"""Identical-art detection. A pair is a twin if ORB cross-inliers >= 50, OR
(dHash distance <= 6 AND cross-inliers >= 15). Thresholds from the 2026-07-08
image-similarity spike.

⚠️ **dHash is the load-bearing signal, and this cannot be done from the pack instead.** Measured
2026-08-07 over 9,455 candidate pairs, comparing the pack's own STORED descriptors card-to-card
rather than the images: known identical-art twins scored `base1-2`/`base4-2` = **40**,
`base4-2`/`cel25cc-CC001` = 98, `me02.5-057`/`sv08-057` = 406 — while the whole candidate
distribution sat at median **60**, p75 **147**. There is no threshold that separates them, because
every Pokemon card shares a template and unrelated cards match on frame geometry, and because the
pack's reference art comes from mixed sources (webp vs the TCGplayer JPEG fallback). Do not try to
avoid the image download by reusing the pack — it was tried and it does not work.
"""
import cv2
import numpy as np
from . import constants as c

def _orb():
    p = c.ORB_PARAMS
    return cv2.ORB_create(nfeatures=1000, scaleFactor=p["scaleFactor"], nlevels=p["nlevels"],
        edgeThreshold=p["edgeThreshold"], firstLevel=p["firstLevel"], WTA_K=p["WTA_K"],
        scoreType=cv2.ORB_HARRIS_SCORE, patchSize=p["patchSize"], fastThreshold=p["fastThreshold"])

def dhash(gray: np.ndarray) -> int:
    s = cv2.resize(gray, (9, 8), interpolation=cv2.INTER_AREA)
    bits = (s[:, 1:] > s[:, :-1]).flatten()
    return int("".join("1" if b else "0" for b in bits), 2)

def cross_inliers(gray_a: np.ndarray, gray_b: np.ndarray) -> int:
    orb = _orb()
    ka, da = orb.detectAndCompute(gray_a, None)
    kb, db = orb.detectAndCompute(gray_b, None)
    if da is None or db is None or len(ka) < 4 or len(kb) < 4:
        return 0
    knn = cv2.BFMatcher(cv2.NORM_HAMMING).knnMatch(da, db, k=2)
    pa, pb = [], []
    for m in knn:
        if len(m) == 2 and m[0].distance < 0.75 * m[1].distance:
            pa.append(ka[m[0].queryIdx].pt); pb.append(kb[m[0].trainIdx].pt)
    if len(pa) < 4:
        return len(pa)
    _, mask = cv2.findHomography(np.array(pa), np.array(pb), cv2.RANSAC, 5.0)
    return 0 if mask is None else int(mask.sum())

def is_twin(gray_a: np.ndarray, gray_b: np.ndarray, require_dhash: bool = False) -> bool:
    """`require_dhash` drops the ORB-only branch, leaving only "the illustration is the same".

    Used for the WIDER (name, artist) pool. Inside the original (number, name) pool the ORB-only
    branch is validated by the 2026-07-08 spike and kept as-is; across the wider pool it is not safe,
    because same-artist cards of the SAME species share far more than a template and ORB alone
    reaches 50 on that resemblance (measured: median 60 across all candidate pairs). dHash is what
    distinguishes "the same picture" from "two pictures of Pikachu by Ken Sugimori"."""
    ci = cross_inliers(gray_a, gray_b)
    if ci >= 50 and not require_dhash:
        return True
    dd = bin(dhash(gray_a) ^ dhash(gray_b)).count("1")
    return dd <= 6 and ci >= 15
