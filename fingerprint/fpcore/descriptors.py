import base64
import json
from dataclasses import dataclass
import cv2
import numpy as np
from . import constants as c

@dataclass
class Keypoint:
    x: float; y: float; size: float; angle: float; response: float

def _orb():
    p = c.ORB_PARAMS
    return cv2.ORB_create(
        nfeatures=p["nfeatures"], scaleFactor=p["scaleFactor"], nlevels=p["nlevels"],
        edgeThreshold=p["edgeThreshold"], firstLevel=p["firstLevel"], WTA_K=p["WTA_K"],
        scoreType=cv2.ORB_HARRIS_SCORE, patchSize=p["patchSize"], fastThreshold=p["fastThreshold"],
    )

def extract(canon_gray: np.ndarray):
    orb = _orb()
    cv_kps, desc = orb.detectAndCompute(canon_gray, None)
    if desc is None:
        return [], np.zeros((0, 32), dtype=np.uint8)
    kps = [Keypoint(k.pt[0], k.pt[1], k.size, k.angle, k.response) for k in cv_kps]
    return kps, np.ascontiguousarray(desc, dtype=np.uint8)

def to_reference_json(kps, desc) -> dict:
    return {
        "fp_version": c.FP_VERSION, "canon_w": c.CANON_W, "canon_h": c.CANON_H,
        "n": len(kps),
        "keypoints": [[k.x, k.y, k.size, k.angle, k.response] for k in kps],
        "descriptors_b64": base64.b64encode(desc.tobytes()).decode("ascii"),
    }

def write_reference(path: str, kps, desc) -> None:
    with open(path, "w") as f:
        json.dump(to_reference_json(kps, desc), f)

def read_reference(path: str):
    doc = json.load(open(path))
    n = doc["n"]
    desc = np.frombuffer(base64.b64decode(doc["descriptors_b64"]), dtype=np.uint8).reshape(n, 32).copy()
    kps = [Keypoint(*row) for row in doc["keypoints"]]
    return kps, np.ascontiguousarray(desc)
