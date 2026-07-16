import cv2
import numpy as np
from . import constants as c

def canonicalize(bgr: np.ndarray) -> np.ndarray:
    """BGR image of any size -> CANON_H x CANON_W grayscale uint8.
    Fixed INTER_AREA resize + BGR2GRAY so both platforms match."""
    resized = cv2.resize(bgr, (c.CANON_W, c.CANON_H), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)
    return np.ascontiguousarray(gray, dtype=np.uint8)
