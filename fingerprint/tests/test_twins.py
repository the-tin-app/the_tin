import numpy as np
from fpcore import twins

def _img(seed):
    rng = np.random.default_rng(seed)
    return rng.integers(0, 255, (920, 660), dtype=np.uint8)

def test_identical_image_is_twin():
    g = _img(1)
    assert twins.is_twin(g, g.copy()) is True

def test_unrelated_images_are_not_twins():
    assert twins.is_twin(_img(1), _img(2)) is False

def test_dhash_identical_is_zero_distance():
    g = _img(3)
    assert bin(twins.dhash(g) ^ twins.dhash(g.copy())).count("1") == 0
