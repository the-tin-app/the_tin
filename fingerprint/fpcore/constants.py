"""Single source of truth for the fingerprint format (Python side).
Any change here that affects output bytes MUST bump FP_VERSION and be mirrored
in ios/TheTin/Sources/Scanner/FingerprintConstants.swift."""

FP_VERSION = 3

CANON_W = 660
CANON_H = 920

ORB_PARAMS = {
    "nfeatures": 650,
    "scaleFactor": 1.2,
    "nlevels": 8,
    "edgeThreshold": 31,
    "firstLevel": 0,
    "WTA_K": 2,
    "patchSize": 31,
    "fastThreshold": 20,
}

# BoVW global-vector vocabulary (Plan 2). Device mirror + guard land in Plan 3.
CODEBOOK_K = 512
GLOBAL_VEC_DIM = CODEBOOK_K


def params_dict() -> dict:
    """Portable snapshot of the fingerprint constants for cross-language
    parity checks (see ios/TheTin/Tests/FingerprintConstantsParityTests.swift)."""
    return {
        "fp_version": FP_VERSION,
        "canon_w": CANON_W,
        "canon_h": CANON_H,
        "orb": ORB_PARAMS,
        "codebook_k": CODEBOOK_K,
        "global_vec_dim": GLOBAL_VEC_DIM,
    }
