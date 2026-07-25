"""Distribution artifacts for the fingerprint pack.

Two formats are published side by side during the rollout:

**Legacy (frozen)** — one gzipped sqlite + `fingerprint/manifest.json`. Mirrors the catalog
publish flow (functions/src/pipeline/publish.ts): gzip the sqlite, sha256 the GZIPPED bytes.
Keep emitting it until no build in the wild still reads it; the client contract is frozen.

**Parts (current)** — the sqlite split verbatim into fixed-size parts under
`fingerprint/parts/`, with its own manifest. No compression, deliberately: ORB descriptors are
high-entropy binary and do not compress (measured 41,600 B -> 41,613 B, i.e. gzip makes them
marginally *bigger*). Across a whole pack gzip returns ~9%, all of it from the keypoint floats
— and it costs the client a whole-buffer inflate, which is what forced the entire ~800 MB pack
through memory. Dropping it lets the client stream each part straight to its offset on disk, so
peak memory is one part and the download resumes part-by-part.

Routed by *format*, not pack version: `fingerprint/parts/` keeps serving v5, v6, ... without a
new directory per rebuild. Part filenames carry the version so two pack versions can sit in the
served directory during a publish.
"""
import gzip
import hashlib
import os
from . import constants as c

#: Wire chunk for the parts format. 50 MB keeps client peak memory small while keeping the
#: part count (and manifest size) modest for a ~800 MB pack.
PART_BYTES = 50 * 1024 * 1024


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


def parts_dir_name() -> str:
    """Served subdirectory for the parts format (parallel to `fingerprint/`)."""
    return "fingerprint/parts"


def part_path(version: int, index: int) -> str:
    """Object path of one part. Zero-padded to 3 digits — a 50 MB part size caps a
    plausible pack well under 1000 parts, and fixed width keeps the served dir sorted."""
    return f"{parts_dir_name()}/fingerprints-v{version}.part{index:03d}"


def split_into_parts(db_path: str, out_root: str, version: int,
                     part_bytes: int = PART_BYTES) -> tuple[str, int, list[dict]]:
    """Write `db_path` verbatim as fixed-size part files under `out_root`, streaming.

    Returns `(whole_sha256, total_bytes, parts)` where `parts` carries one entry per part
    with its object path, sha256 and byte count. Never holds more than `part_bytes` in
    memory — the packs this runs on are ~800 MB.

    Parts are a plain byte split: concatenating them in index order reproduces the sqlite
    exactly, so the client can write each part at `index * part_bytes` and skip assembly.
    """
    if part_bytes <= 0:
        raise ValueError("part_bytes must be positive")

    whole = hashlib.sha256()
    parts: list[dict] = []
    total = 0

    with open(db_path, "rb") as src:
        while True:
            chunk = src.read(part_bytes)
            if not chunk:
                break
            index = len(parts)
            rel = part_path(version, index)
            dest = os.path.join(out_root, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as f:
                f.write(chunk)
            whole.update(chunk)
            total += len(chunk)
            parts.append({
                "path": rel,
                "sha256": hashlib.sha256(chunk).hexdigest(),
                "bytes": len(chunk),
            })

    if not parts:
        raise ValueError(f"{db_path} is empty — nothing to publish")
    return whole.hexdigest(), total, parts


def make_parts_manifest(version: int, codebook_hash: str, generated_at: str,
                        whole_sha256: str, size_bytes: int, parts: list[dict],
                        part_bytes: int = PART_BYTES, fp_version: int = c.FP_VERSION,
                        canon_w: int = c.CANON_W, canon_h: int = c.CANON_H) -> dict:
    """Manifest for the parts format. Superset of the legacy manifest: same gate fields
    (version / fpVersion / codebookHash / canonical dims) so the client's compatibility
    checks are unchanged, plus `partSize` + `parts[]`.

    `sha256`/`sizeBytes` describe the *assembled, uncompressed* sqlite — unlike the legacy
    manifest where both describe the gzipped bytes. Per-part sha256 lets a corrupt part be
    refetched on its own instead of restarting the whole download; the whole-file sha256
    stays the end-to-end gate before install.
    """
    return {
        "version": version,
        "format": "parts",
        "partSize": part_bytes,
        "parts": parts,
        "sha256": whole_sha256,
        "sizeBytes": size_bytes,
        "generatedAt": generated_at,
        "fpVersion": fp_version,
        "codebookHash": codebook_hash,
        "canonicalW": canon_w,
        "canonicalH": canon_h,
    }
