"""Binary Bag-of-Visual-Words codebook for ORB descriptors.

k-majority clustering (Hamming assignment, per-bit majority-vote centroids) so
that word assignment is pure integer math (popcount(desc XOR centroid)) and
therefore bit-exact across Python (server) and OpenCV-iOS (device). tf-idf global
vector; idf computed over the training cards. See the Plan 2 design doc."""
import hashlib
import struct
import numpy as np
from . import constants as c

_MAGIC = b"FPCB"
_FORMAT_VERSION = 1
_DESC_BYTES = 32


def _assign_bits(bits: np.ndarray, centroid_bits: np.ndarray) -> np.ndarray:
    """bits: (n,256) int, centroid_bits: (K,256) int (both 0/1).
    Hamming(a,c) = popcount(a) + popcount(c) - 2*(a·c). Returns argmin word ids
    (ties broken to the lowest index by np.argmin)."""
    sum_b = bits.sum(axis=1)              # (n,)
    sum_c = centroid_bits.sum(axis=1)     # (K,)
    dot = bits @ centroid_bits.T          # (n,K)
    dist = sum_b[:, None] + sum_c[None, :] - 2 * dot
    return np.argmin(dist, axis=1)


class Codebook:
    def __init__(self, centroids: np.ndarray, idf: np.ndarray):
        self.centroids = np.ascontiguousarray(centroids, dtype=np.uint8)  # (K,32)
        self.idf = np.ascontiguousarray(idf, dtype=np.float16)            # (K,)
        self._centroid_bits = np.unpackbits(self.centroids, axis=1).astype(np.int32)

    @property
    def K(self) -> int:
        return self.centroids.shape[0]

    def assign_all(self, desc: np.ndarray) -> np.ndarray:
        if len(desc) == 0:
            return np.zeros(0, dtype=np.int64)
        bits = np.unpackbits(np.ascontiguousarray(desc, np.uint8), axis=1).astype(np.int32)
        return _assign_bits(bits, self._centroid_bits).astype(np.int64)

    def assign(self, desc_row: np.ndarray) -> int:
        return int(self.assign_all(np.asarray(desc_row, np.uint8)[None, :])[0])

    def global_vec(self, desc: np.ndarray) -> np.ndarray:
        v = np.zeros(self.K, dtype=np.float64)
        if len(desc):
            words = self.assign_all(desc)
            counts = np.bincount(words, minlength=self.K).astype(np.float64)
            v = counts * self.idf.astype(np.float64)
            norm = np.linalg.norm(v)
            if norm > 0:
                v = v / norm
        return v.astype(np.float16)

    def to_bytes(self) -> bytes:
        header = _MAGIC + struct.pack("<III", _FORMAT_VERSION, self.K, _DESC_BYTES)
        return (header
                + np.ascontiguousarray(self.centroids, np.uint8).tobytes()
                + np.ascontiguousarray(self.idf, "<f2").tobytes())

    def sha256_hex(self) -> str:
        return hashlib.sha256(self.to_bytes()).hexdigest()

    def save(self, path: str) -> None:
        with open(path, "wb") as f:
            f.write(self.to_bytes())

    @staticmethod
    def load(path: str) -> "Codebook":
        with open(path, "rb") as f:
            data = f.read()
        if data[:4] != _MAGIC:
            raise ValueError("not a codebook.bin (bad magic)")
        fmt, K, desc_bytes = struct.unpack("<III", data[4:16])
        if fmt != _FORMAT_VERSION or desc_bytes != _DESC_BYTES:
            raise ValueError(f"unsupported codebook (fmt={fmt}, desc_bytes={desc_bytes})")
        expected = 16 + K * 32 + K * 2
        if len(data) != expected:
            raise ValueError(f"codebook.bin truncated/padded: expected {expected} bytes, got {len(data)}")
        off = 16
        centroids = np.frombuffer(data[off:off + K * 32], np.uint8).reshape(K, 32).copy()
        off += K * 32
        idf = np.frombuffer(data[off:off + K * 2], "<f2").copy()
        return Codebook(centroids, idf)


def train(card_descriptors, K: int = c.CODEBOOK_K, seed: int = 0, iters: int = 10) -> Codebook:
    cards = [np.ascontiguousarray(d, np.uint8) for d in card_descriptors if len(d)]
    if not cards:
        raise ValueError("no descriptors to train on")
    alld = np.concatenate(cards, axis=0)                       # (M,32)
    bits = np.unpackbits(alld, axis=1).astype(np.int32)        # (M,256)
    rng = np.random.default_rng(seed)
    if bits.shape[0] < K:
        raise ValueError(f"need >= K={K} descriptors, got {bits.shape[0]}")
    init = rng.choice(bits.shape[0], size=K, replace=False)
    centroid_bits = bits[init].copy()                          # (K,256) in {0,1}
    for _ in range(iters):
        assign = _assign_bits(bits, centroid_bits)
        for k in range(K):
            members = bits[assign == k]
            if len(members) == 0:
                continue  # keep previous centroid (deterministic)
            # per-bit majority; exact tie (mean == 0.5) -> 0
            centroid_bits[k] = (members.mean(axis=0) > 0.5).astype(np.int32)
    centroids = np.packbits(centroid_bits.astype(np.uint8), axis=1)  # (K,32)

    # idf over cards: df[k] = #cards whose descriptors hit word k at least once
    df = np.zeros(K, dtype=np.int64)
    for d in cards:
        cb_local = np.unpackbits(d, axis=1).astype(np.int32)
        words = np.unique(_assign_bits(cb_local, centroid_bits))
        df[words] += 1
    D = len(cards)
    # Smoothed idf (as in sklearn's TfidfVectorizer, smooth_idf=True): strictly
    # positive for every df in [0, D], unlike the raw log(D/(1+df)) which is
    # exactly 0 whenever df == D-1 (a word appearing in all-but-one document) —
    # degenerate for small D (e.g. D=2), where it would zero out global_vec.
    idf = (np.log((D + 1.0) / (1.0 + df)) + 1.0).astype(np.float16)
    return Codebook(centroids, idf)
