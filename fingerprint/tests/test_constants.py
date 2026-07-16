from fpcore import constants as c

def test_canonical_dimensions_and_ratio():
    assert (c.CANON_W, c.CANON_H) == (660, 920)
    # standard card aspect ≈ 0.717
    assert abs(c.CANON_W / c.CANON_H - 0.717) < 0.005

def test_orb_params_are_fixed_and_complete():
    assert c.FP_VERSION == 3
    assert c.ORB_PARAMS == {
        "nfeatures": 650,
        "scaleFactor": 1.2,
        "nlevels": 8,
        "edgeThreshold": 31,
        "firstLevel": 0,
        "WTA_K": 2,
        "patchSize": 31,
        "fastThreshold": 20,
    }

def test_codebook_constants_present_and_consistent():
    assert c.CODEBOOK_K == 512
    assert c.GLOBAL_VEC_DIM == c.CODEBOOK_K
    p = c.params_dict()
    assert p["codebook_k"] == 512
    assert p["global_vec_dim"] == 512
