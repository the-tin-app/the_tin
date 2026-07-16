"""Identical-art detection for same-number+name catalog pools. A pair is a twin
if ORB cross-inliers >= 50, OR (dHash distance <= 6 AND cross-inliers >= 15).
Thresholds from the 2026-07-08 image-similarity spike."""
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

def is_twin(gray_a: np.ndarray, gray_b: np.ndarray) -> bool:
    ci = cross_inliers(gray_a, gray_b)
    if ci >= 50:
        return True
    dd = bin(dhash(gray_a) ^ dhash(gray_b)).count("1")
    return dd <= 6 and ci >= 15
