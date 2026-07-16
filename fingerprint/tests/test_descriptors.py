import cv2, numpy as np, json
from fpcore.canonicalize import canonicalize
from fpcore import descriptors as d
from fpcore import constants as c

def _canon():
    return canonicalize(cv2.imread("tests/fixtures/card_a.png", cv2.IMREAD_COLOR))

def test_extract_shape():
    kps, desc = d.extract(_canon())
    assert desc.dtype == np.uint8 and desc.shape[1] == 32
    assert 0 < len(kps) <= c.ORB_PARAMS["nfeatures"]
    assert len(kps) == desc.shape[0]

def test_extract_deterministic():
    canon = _canon()
    _, d1 = d.extract(canon)
    _, d2 = d.extract(canon)
    assert np.array_equal(d1, d2)

def test_reference_roundtrip_and_written_file(tmp_path):
    kps, desc = d.extract(_canon())
    p = tmp_path / "ref.json"
    d.write_reference(str(p), kps, desc)
    kps2, desc2 = d.read_reference(str(p))
    assert np.array_equal(desc, desc2)
    assert len(kps) == len(kps2)
    assert desc2.flags.writeable
    desc2[0, 0] = desc2[0, 0]  # would raise ValueError on a read-only buffer
    doc = json.loads(p.read_text())
    assert doc["fp_version"] == c.FP_VERSION and doc["n"] == len(kps)
