"""The iOS-bundled codebook.bin MUST be byte-identical to the canonical one, so
device global vectors are comparable to the shipped pack. Run from fingerprint/."""
import hashlib, os

CANON = "fpcore/codebook.bin"
IOS = "../ios/TheTin/Resources/codebook.bin"
KNOWN = "29f6036053e9ace2129430c317a22291b488266c8de32ff811394c42f31ce131"

def _sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()

def test_ios_copy_matches_canonical():
    assert os.path.exists(IOS), "run: cp fpcore/codebook.bin ../ios/TheTin/Resources/codebook.bin"
    assert _sha(CANON) == KNOWN
    assert _sha(IOS) == KNOWN
