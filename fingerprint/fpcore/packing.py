"""On-disk fingerprint blob packing — the byte contract Plan 3's iOS
FingerprintStore reads. All little-endian. Keypoints are normalized [0,1) float16
(x,y only); descriptors uint8 n*32; global_vec float16 length K. Row i of
keypoints corresponds to row i of descriptors."""
import numpy as np
from . import constants as c


def pack_keypoints(xy_pixels: np.ndarray) -> bytes:
    if len(xy_pixels) == 0:
        return b""
    norm = np.empty((len(xy_pixels), 2), dtype="<f2")
    norm[:, 0] = (xy_pixels[:, 0].astype(np.float32) / c.CANON_W).astype(np.float16)
    norm[:, 1] = (xy_pixels[:, 1].astype(np.float32) / c.CANON_H).astype(np.float16)
    return np.ascontiguousarray(norm, dtype="<f2").tobytes()


def unpack_keypoints(blob: bytes, n: int) -> np.ndarray:
    if n == 0:
        return np.zeros((0, 2), dtype=np.float32)
    norm = np.frombuffer(blob, dtype="<f2").reshape(n, 2).astype(np.float32)
    out = np.empty((n, 2), dtype=np.float32)
    out[:, 0] = norm[:, 0] * c.CANON_W
    out[:, 1] = norm[:, 1] * c.CANON_H
    return out


def pack_descriptors(desc: np.ndarray) -> bytes:
    if len(desc) == 0:
        return b""
    assert desc.dtype == np.uint8 and desc.shape[1] == 32
    return np.ascontiguousarray(desc, dtype=np.uint8).tobytes()


def unpack_descriptors(blob: bytes, n: int) -> np.ndarray:
    if n == 0:
        return np.zeros((0, 32), dtype=np.uint8)
    return np.frombuffer(blob, dtype=np.uint8).reshape(n, 32).copy()


def pack_global_vec(vec: np.ndarray) -> bytes:
    return np.ascontiguousarray(vec, dtype="<f2").tobytes()


def unpack_global_vec(blob: bytes) -> np.ndarray:
    return np.frombuffer(blob, dtype="<f2").copy()
