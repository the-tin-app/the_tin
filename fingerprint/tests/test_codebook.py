import hashlib
import numpy as np
from fpcore import codebook as cb

def _two_clusters(n=50, seed=1):
    rng = np.random.default_rng(seed)
    # cluster A near all-zeros, cluster B near all-ones (32 bytes = 256 bits)
    a = (rng.random((n, 32)) < 0.1).astype(np.uint8) * 255
    b = (rng.random((n, 32)) < 0.9).astype(np.uint8) * 255
    return [a, b]

def test_train_is_deterministic():
    cards = _two_clusters()
    c1 = cb.train(cards, K=2, seed=0, iters=5)
    c2 = cb.train(cards, K=2, seed=0, iters=5)
    assert np.array_equal(c1.centroids, c2.centroids)
    assert np.array_equal(np.asarray(c1.idf), np.asarray(c2.idf))

def test_assign_returns_nearest_hamming_centroid():
    # hand-built centroids: word 0 = all bits 0, word 1 = all bits 1
    centroids = np.zeros((2, 32), dtype=np.uint8)
    centroids[1, :] = 255
    idf = np.ones(2, dtype=np.float16)
    book = cb.Codebook(centroids, idf)
    near_zero = np.zeros((1, 32), dtype=np.uint8)
    near_one = np.full((1, 32), 255, dtype=np.uint8)
    assert book.assign(near_zero[0]) == 0
    assert book.assign(near_one[0]) == 1
    assert list(book.assign_all(np.vstack([near_zero, near_one]))) == [0, 1]

def test_train_recovers_two_clusters():
    cards = _two_clusters()
    book = cb.train(cards, K=2, seed=0, iters=8)
    # all cluster-A descriptors map to one word, cluster-B to the other
    a_words = set(book.assign_all(cards[0]).tolist())
    b_words = set(book.assign_all(cards[1]).tolist())
    assert len(a_words) == 1 and len(b_words) == 1 and a_words != b_words

def test_assign_all_empty():
    book = cb.Codebook(np.zeros((2, 32), np.uint8), np.ones(2, np.float16))
    assert book.assign_all(np.zeros((0, 32), np.uint8)).shape == (0,)

def test_global_vec_is_l2_normalized_and_discriminates():
    cards = _two_clusters()
    book = cb.train(cards, K=2, seed=0, iters=8)
    va = book.global_vec(cards[0])
    vb = book.global_vec(cards[1])
    assert va.dtype == np.float16
    assert abs(float(np.linalg.norm(va.astype(np.float64))) - 1.0) < 1e-2
    cos_aa = float(np.dot(va.astype(np.float64), va.astype(np.float64)))
    cos_ab = float(np.dot(va.astype(np.float64), vb.astype(np.float64)))
    assert cos_aa > cos_ab  # a card matches itself better than the other cluster

def test_global_vec_empty_is_zero():
    book = cb.Codebook(np.zeros((2, 32), np.uint8), np.ones(2, np.float16))
    v = book.global_vec(np.zeros((0, 32), np.uint8))
    assert v.shape == (2,) and not np.any(v)

def test_save_load_roundtrip_and_stable_hash(tmp_path):
    cards = _two_clusters()
    book = cb.train(cards, K=2, seed=0, iters=8)
    p = tmp_path / "codebook.bin"
    book.save(str(p))
    loaded = cb.Codebook.load(str(p))
    assert np.array_equal(loaded.centroids, book.centroids)
    assert np.array_equal(np.asarray(loaded.idf), np.asarray(book.idf))
    assert loaded.sha256_hex() == book.sha256_hex()
    # hash is the sha256 of the on-disk bytes
    assert hashlib.sha256(p.read_bytes()).hexdigest() == book.sha256_hex()

def test_codebook_bin_has_magic_header(tmp_path):
    book = cb.train(_two_clusters(), K=2, seed=0, iters=3)
    p = tmp_path / "codebook.bin"
    book.save(str(p))
    assert p.read_bytes()[:4] == b"FPCB"

def test_train_over_fixtures_is_reproducible():
    import cv2
    from fpcore import canonicalize, descriptors as d
    cards = []
    for name in ("card_a", "card_b"):
        _, desc = d.extract(canonicalize.canonicalize(cv2.imread(f"tests/fixtures/{name}.png")))
        cards.append(desc)
    h1 = cb.train(cards, K=64, seed=7, iters=6).sha256_hex()
    h2 = cb.train(cards, K=64, seed=7, iters=6).sha256_hex()
    assert h1 == h2  # same descriptors + seed + iters -> identical codebook bytes

def test_load_rejects_bad_magic(tmp_path):
    p = tmp_path / "bad.bin"
    p.write_bytes(b"XXXX" + b"\x00" * 32)
    import pytest
    with pytest.raises(ValueError):
        cb.Codebook.load(str(p))

def test_load_rejects_truncated_file(tmp_path):
    book = cb.train(_two_clusters(), K=2, seed=0, iters=3)
    p = tmp_path / "cb.bin"
    book.save(str(p))
    data = p.read_bytes()
    p.write_bytes(data[:-4])  # drop 4 bytes -> length mismatch
    import pytest
    with pytest.raises(ValueError):
        cb.Codebook.load(str(p))

def test_load_rejects_bad_format_version(tmp_path):
    import struct, pytest
    book = cb.train(_two_clusters(), K=2, seed=0, iters=3)
    p = tmp_path / "cb.bin"
    book.save(str(p))
    data = bytearray(p.read_bytes())
    struct.pack_into("<I", data, 4, 999)  # corrupt format_version field
    p.write_bytes(bytes(data))
    with pytest.raises(ValueError):
        cb.Codebook.load(str(p))
