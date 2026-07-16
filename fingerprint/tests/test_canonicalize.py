import cv2, numpy as np
from fpcore.canonicalize import canonicalize
from fpcore import constants as c

def _load():
    return cv2.imread("tests/fixtures/card_a.png", cv2.IMREAD_COLOR)

def test_output_shape_and_dtype():
    out = canonicalize(_load())
    assert out.shape == (c.CANON_H, c.CANON_W)
    assert out.dtype == np.uint8

def test_deterministic():
    img = _load()
    assert np.array_equal(canonicalize(img), canonicalize(img))
