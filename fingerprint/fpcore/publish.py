"""Distribution artifacts for the fingerprint pack — mirrors the catalog
publish flow (functions/src/pipeline/publish.ts): gzip the sqlite, sha256 the
GZIPPED bytes, emit a manifest. Storage object layout parallels catalog/:
  fingerprint/fingerprints-v{version}.sqlite.gz
  fingerprint/manifest.json"""
import gzip
import hashlib
from . import constants as c


def gzip_bytes(data: bytes) -> bytes:
    return gzip.compress(data, compresslevel=9, mtime=0)


def make_manifest(gz_bytes: bytes, version: int, codebook_hash: str,
                  generated_at: str, fp_version: int = c.FP_VERSION,
                  canon_w: int = c.CANON_W, canon_h: int = c.CANON_H) -> dict:
    return {
        "version": version,
        "path": f"fingerprint/fingerprints-v{version}.sqlite.gz",
        "sha256": hashlib.sha256(gz_bytes).hexdigest(),
        "sizeBytes": len(gz_bytes),
        "generatedAt": generated_at,
        "fpVersion": fp_version,
        "codebookHash": codebook_hash,
        "canonicalW": canon_w,
        "canonicalH": canon_h,
    }
