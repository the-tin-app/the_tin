"""Builds detection-level test fixtures (the layer LabeledPhotoAccuracyTests bypasses):
  binder-montage.pngdata   — synthetic 9-pocket binder page, 1080x1920, center card IMG_1539
                             (hgss3-39). Guards ScanGuide crop + center-ranked quad selection:
                             without them doc-seg returns the whole page (reproduced 2026-07-15).
  fullframe-<num>.pngdata  — three real single-card photos at live resolution (long side 1920),
                             exercising doc-seg + rectify + orientation end-to-end in-suite.
Run from repo root: fingerprint/.venv/bin/python fingerprint/scripts/make_detection_fixtures.py
Deterministic (no randomness) — safe to re-run; commit the outputs.
"""
import cv2
import numpy as np
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = ROOT / "ios/TheTin/Tests/Fixtures/ScanPhotos"

# 3x3 grid, center = IMG_1539 (hgss3-39). Neighbors chosen for distinct truths; 1538/1539 are
# both Togetic prints, deliberately adjacent — a name-collision worst case for the crop.
GRID = ["IMG_1535", "IMG_1536", "IMG_1537",
        "IMG_1538", "IMG_1539", "IMG_1540",
        "IMG_1544", "IMG_1557", "IMG_1577"]

def montage():
    cw, ch, gap = 330, 460, 18
    W, H = 3 * cw + 4 * gap, 3 * ch + 4 * gap
    page = np.full((H, W, 3), 40, np.uint8)              # dark binder-page background
    for i, name in enumerate(GRID):
        buf = np.frombuffer((FIX / f"{name}.pngdata").read_bytes(), np.uint8)
        img = cv2.resize(cv2.imdecode(buf, cv2.IMREAD_COLOR), (cw, ch))
        r, c = divmod(i, 3)
        page[gap + r*(ch+gap):gap + r*(ch+gap)+ch, gap + c*(cw+gap):gap + c*(cw+gap)+cw] = img
    FW, FH = 1080, 1920
    frame = np.full((FH, FW, 3), 25, np.uint8)           # portrait live-camera frame
    # Aim at the CENTER pocket (real usage — a user frames one card, not the whole page). Scale
    # the page so the center card fills ~56% of the frame width (≈ the guide window) and the whole
    # page overflows the frame on every side. This is what makes the binder fix testable: with the
    # page bigger than the frame there is NO whole-page quad to capture, and the whole-page doc-seg
    # quad (if any) blows past the guide window's 1.15× size cap — so guide-constrained selection
    # keeps the aimed center card. (The center cell is at the page center by construction.) The
    # earlier framing scaled the whole page to fit the frame, which left the center card ~306px and
    # let a whole-page quad sit inside the guide window.
    s = (FW * 0.56) / cw
    page = cv2.resize(page, (int(W*s), int(H*s)))
    ph, pw = page.shape[:2]
    y0, x0 = (FH - ph) // 2, (FW - pw) // 2               # page center → frame center (both negative)
    dy0, dx0 = max(0, y0), max(0, x0)
    sy0, sx0 = max(0, -y0), max(0, -x0)
    dh = min(FH, y0 + ph) - dy0
    dw = min(FW, x0 + pw) - dx0
    frame[dy0:dy0+dh, dx0:dx0+dw] = page[sy0:sy0+dh, sx0:sx0+dw]
    (FIX / "binder-montage.pngdata").write_bytes(cv2.imencode(".png", frame)[1].tobytes())
    print("binder-montage.pngdata", frame.shape, "center-card-px", int(cw*s))

def fullframes():
    for num in ["1535", "1557", "1577"]:
        srcs = list((ROOT / "test_images").glob(f"IMG_{num}*.HEIC"))
        assert srcs, f"missing test_images HEIC for {num}"
        # cv2 can't read HEIC — go through sips (macOS-only, matches the eval harness).
        import subprocess, tempfile
        with tempfile.NamedTemporaryFile(suffix=".png") as tmp:
            subprocess.run(["sips", "-s", "format", "png", "-Z", "1920",
                            str(srcs[0]), "--out", tmp.name], check=True, capture_output=True)
            img = cv2.imread(tmp.name)
        # The live camera is portrait-locked (AVCaptureConnection fixed to portrait — see the
        # a426d9b "camera portrait-orientation" fix); a real frame is never landscape. A couple
        # of the reference HEICs were shot with the phone rotated (sips preserves that), which
        # produced a landscape frame here — not a shape the production pipeline ever sees, and
        # ScanGuide's portrait-card crop would clip a landscape-framed card. Normalize to
        # portrait so the fixture matches what AVCaptureSession actually delivers.
        if img.shape[1] > img.shape[0]:
            img = cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
        (FIX / f"fullframe-{num}.pngdata").write_bytes(cv2.imencode(".png", img)[1].tobytes())
        print(f"fullframe-{num}.pngdata", img.shape)

def binder_sideways():
    # IMG_1629: real binder pocket (Mega Clefable me03-031) with the card's long axis
    # PERPENDICULAR to the guide window's — the posture of standing over a flat binder.
    # Deliberately NOT portrait-normalized: rotating would stand the card upright and erase
    # the scenario under test. The 2026-07-15 on-device binder failure: an orientation-naive
    # guide FITS check rejected the sideways card quad, and a small card-aspect glare
    # fragment (435x309) "passed the guide" instead → zoomed garbage plate (focus ~4) that
    # the minFocus gate then silently ate. This fixture regression-gates both halves
    # (orientation-neutral fits + the minimum-size guard).
    import subprocess, tempfile
    srcs = list((ROOT / "test_images").glob("IMG_1629*.HEIC"))
    assert srcs, "missing test_images HEIC for 1629"
    with tempfile.NamedTemporaryFile(suffix=".png") as tmp:
        subprocess.run(["sips", "-s", "format", "png", "-Z", "1920",
                        str(srcs[0]), "--out", tmp.name], check=True, capture_output=True)
        img = cv2.imread(tmp.name)
    (FIX / "fullframe-1629.pngdata").write_bytes(cv2.imencode(".png", img)[1].tobytes())
    print("fullframe-1629.pngdata", img.shape)

montage()
fullframes()
binder_sideways()
