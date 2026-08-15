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


def test_require_dhash_drops_the_orb_only_branch():
    """The wider (name, artist) pool must not accept a pair on ORB alone.

    ⚠️ Measured 2026-08-07: across same-species/same-artist candidate pairs, ORB cross-inliers sit at a
    median of 60 — cards of the same Pokemon by the same illustrator resemble each other far beyond the
    shared template, so the ORB-only branch that is safe inside a (number, name) pool admits real
    non-twins across the wider one. dHash is what separates "the same picture" from "two pictures of
    the same Pokemon by the same artist".
    """
    import numpy as np
    from fpcore import twins

    a = np.zeros((920, 660), dtype=np.uint8)
    b = np.zeros((920, 660), dtype=np.uint8)
    # Two images with a strong shared structure but different content: identical frame, different fill.
    a[40:880, 40:620] = 200
    b[40:880, 40:620] = 200
    rng = np.random.default_rng(7)
    a[200:700, 100:560] = rng.integers(0, 255, (500, 460), dtype=np.uint8)
    b[200:700, 100:560] = rng.integers(0, 255, (500, 460), dtype=np.uint8)

    # Whatever the ORB score, requiring dHash cannot pass a pair whose pictures differ.
    assert twins.is_twin(a, b, require_dhash=True) is False
