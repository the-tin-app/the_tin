# Recognizer eval harness (through-plastic accuracy)

Offline harness that measures the augmented recognizer (OCR-narrow → visual-confirm) on the
65 real photos in `../../test_images/` (HEIC) + `../../test_images/images.csv` (labels:
`image_num, name, hp, numerator, denominator, condition`; conditions: `raw`/`plain`=bare,
`sleeve`=penny, `perfect`=perfect-fit, `top-sleeve`=toploader, `case-sleeve`=one-touch).

These scripts were the spike that set every Plan 2 parameter (nf=650, Lowe 0.80, margin 1.3,
document-segmentation detection, full-plate OCR, twin→chooser). They double as **reference
implementations** for the Plan 2 iOS tasks. Paths inside the scripts are absolute to the
original scratch run — **adjust `CAT`/`CACHE`/`PLATES` constants to your checkout** before
running.

## Inputs
- `../../test_images/*.HEIC` + `images.csv` — the 65 labeled photos.
- Catalog: `../../functions/.seed-output/catalog/catalog-v3.sqlite.gz` (gunzip a copy first).
- Card art: `../.cache/images/<card_id>.webp` (~21k images, already cached, ~1.4 GB).
- `truth.txt` — resolved `image_num → card_id` (60 confident rows; the Articuno is `np-32`
  "Articuno ex", which name+number+denominator couldn't pin but the visual matcher nailed).

## Pipeline
1. `resolve_truth.py` — resolve each CSV row to a card_id via the catalog; flags ambiguous
   rows (printed denominator ≠ catalog total, promos). Output committed as `truth.txt`.
2. `detect_ocr.swift` — `swift detect_ocr.swift`. HEIC → `VNDetectDocumentSegmentation` →
   natural-aspect perspective-correct → orientation-normalize (pick the rotation whose text
   OCRs best) → full-plate `VNRecognizeText` → `ocr_results.json` + rectified plates.
   **Reference for CardDetector (doc-seg + orientation) and TextGate (full-plate OCR).**
3. `scorer.py` — `.venv/bin/python scorer.py`. The EXACT production matcher (BFMatcher
   NORM_HAMMING, Lowe 0.75 — bump to 0.80 for Plan 2, homography RANSAC 5.0) + soft-narrow
   (name ∪ number ∪ attack-name) + consistency gate. Classifies each photo
   auto-lock-ok / auto-lock-WRONG / chooser-hit / chooser-miss, per condition.
   **Reference for CandidateIndex narrowing and the ScanSession gate.**
4. `sweep_nf.py` — reproduces the nf 300–1000 size/accuracy sweep (the nf=650 knee).

## Headline results (nf=1000; nf=650 ≈ same)
name OCR 100% through every plastic type; number OCR 68%; auto-lock ~70%; chooser ~20%;
**1 confident wrong-lock in 64** — the identical-art Blastoise (`base4-2` vs `base1-2`) when
the denominator failed to OCR — which Plan 1's `card_twin` table + the twin→chooser gate
drive to 0.

See `[[ocr-recognizer-spike-findings]]` (memory) and
`docs/handoff/2026-07-08-plan2-recognizer-handoff.md` for the full analysis.

## 2026-07-15 live-gap experiment (scan-live-gap-diagnosis memory)
Re-ran this harness at live camera resolution (HEICs downscaled to 1920 long side) with prod
params (nf=650, floor 20, margin 1.3, Lowe 0.80) and refs from the built v3 pack: auto-lock
43/64 vs 42 at full res, name OCR 98% — resolution is NOT the live gap. The gaps were
detection (guide-constrained quad selection: ScanGuide window + fits/center filters + rectangles
union) and latency (median pool 137 × ~12ms/candidate/frame), both fixed + regression-gated by
DetectionAccuracyTests and Matcher.matchRanked.
