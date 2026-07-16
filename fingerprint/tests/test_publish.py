import gzip
import hashlib
from fpcore import publish, constants as c


def test_gzip_is_deterministic_and_valid():
    data = b"hello fingerprint" * 100
    g1 = publish.gzip_bytes(data)
    g2 = publish.gzip_bytes(data)
    assert g1 == g2                       # reproducible (mtime=0)
    assert gzip.decompress(g1) == data


def test_manifest_shape_matches_catalog_convention():
    gz = publish.gzip_bytes(b"sqlite-bytes")
    m = publish.make_manifest(gz, version=3, codebook_hash="cbhash",
                              generated_at="2026-07-07T00:00:00Z")
    # catalog-parallel fields
    assert m["version"] == 3
    assert m["path"] == "fingerprint/fingerprints-v3.sqlite.gz"
    assert m["sha256"] == hashlib.sha256(gz).hexdigest()  # sha256 of GZIPPED bytes
    assert m["sizeBytes"] == len(gz)
    assert m["generatedAt"] == "2026-07-07T00:00:00Z"
    # fingerprint-specific gate fields
    assert m["fpVersion"] == c.FP_VERSION
    assert m["codebookHash"] == "cbhash"
    assert m["canonicalW"] == c.CANON_W
    assert m["canonicalH"] == c.CANON_H
