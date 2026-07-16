import numpy as np
from fpcore import packing, constants as c

def test_keypoints_roundtrip_within_float16_tolerance():
    xy = np.array([[0.0, 0.0], [659.0, 919.0], [330.0, 460.0]], dtype=np.float32)
    blob = packing.pack_keypoints(xy)
    assert len(blob) == 3 * 2 * 2  # n*2 float16
    back = packing.unpack_keypoints(blob, 3)
    assert back.dtype == np.float32
    # float16 in [0,1] gives sub-pixel error after scaling back
    assert np.max(np.abs(back[:, 0] - xy[:, 0])) < 1.0
    assert np.max(np.abs(back[:, 1] - xy[:, 1])) < 1.0

def test_keypoints_are_normalized_little_endian():
    xy = np.array([[c.CANON_W / 2.0, c.CANON_H / 2.0]], dtype=np.float32)
    blob = packing.pack_keypoints(xy)
    vals = np.frombuffer(blob, dtype="<f2")
    assert abs(float(vals[0]) - 0.5) < 0.01  # x normalized ~0.5
    assert abs(float(vals[1]) - 0.5) < 0.01  # y normalized ~0.5

def test_descriptors_roundtrip_exact():
    desc = (np.arange(2 * 32, dtype=np.uint8) % 256).astype(np.uint8).reshape(2, 32)
    blob = packing.pack_descriptors(desc)
    assert len(blob) == 2 * 32
    assert np.array_equal(packing.unpack_descriptors(blob, 2), desc)

def test_global_vec_roundtrip():
    vec = np.linspace(0, 1, c.GLOBAL_VEC_DIM).astype(np.float16)
    blob = packing.pack_global_vec(vec)
    assert len(blob) == c.GLOBAL_VEC_DIM * 2
    back = packing.unpack_global_vec(blob)
    assert back.dtype == np.float16 and np.array_equal(back, vec)

def test_empty_keypoints_and_descriptors():
    assert packing.pack_keypoints(np.zeros((0, 2), np.float32)) == b""
    assert packing.unpack_keypoints(b"", 0).shape == (0, 2)
    assert packing.pack_descriptors(np.zeros((0, 32), np.uint8)) == b""
