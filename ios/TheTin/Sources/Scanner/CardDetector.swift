import CoreImage
import CoreVideo
import Vision

enum PerspectiveCorrector {
    static func canonicalBGRA(from ci: CIImage, quad: CardQuad, context: CIContext) -> (data: Data, bytesPerRow: Int)? {
        guard let f = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(CIVector(cgPoint: quad.topLeft), forKey: "inputTopLeft")
        f.setValue(CIVector(cgPoint: quad.topRight), forKey: "inputTopRight")
        f.setValue(CIVector(cgPoint: quad.bottomLeft), forKey: "inputBottomLeft")
        f.setValue(CIVector(cgPoint: quad.bottomRight), forKey: "inputBottomRight")
        guard let corrected = f.outputImage else { return nil }
        let w = Int(kFPCanonW), h = Int(kFPCanonH)
        let scaled = corrected.transformed(by: CGAffineTransform(
            scaleX: CGFloat(w) / corrected.extent.width, y: CGFloat(h) / corrected.extent.height))
        let stride = w * 4
        var buf = [UInt8](repeating: 0, count: stride * h)
        buf.withUnsafeMutableBytes { raw in
            context.render(scaled, toBitmap: raw.baseAddress!, rowBytes: stride,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return (Data(buf), stride)
    }
}

/// Detects a card-shaped quad — preferring `VNDetectDocumentSegmentationRequest` (robust to
/// low contrast / glare / rounded toploader corners / full-art borders), falling back to
/// `VNDetectRectanglesRequest` when doc-seg finds nothing — and perspective-corrects it to a
/// natural-aspect `CIImage` (orientation not yet resolved). Ported from the proven reference
/// `fingerprint/eval/detect_ocr.swift`'s `rectify()`, validated 100% on 65 real photos.
enum CardRectifier {
    struct Result {
        let corrected: CIImage   // natural aspect; orientation resolved later by OrientationNormalizer
        let confidence: Double
    }

    // Guide-window quad SELECTION (the binder fix). `ci`/`handler` run on the FULL frame —
    // NOT a pre-cropped one. Cropping the pixels before Vision was tried (task 6, 9d6acd6) and
    // abandoned: `VNDetectDocumentSegmentationRequest` is non-deterministic on cropped input in
    // this environment even when the crop is eagerly rendered to a CGImage (5 identical calls →
    // conf 0.000/0.965/0.828/0.990/0.955) and returns degenerate quads (the whole-crop box, or a
    // non-card horizontal band); the crop also HURT single-card detection (fullframe-1557 matches
    // at 136 inliers uncropped, fails cropped). Full-frame doc-seg is the production-proven path.
    // So we detect on the full frame and instead
    // CONSTRAIN which quad we keep to the guide window the user aims at (ScanGuide.cropRect): a
    // whole-binder-page quad (conf ~0.99) fails the FITS check and is rejected, and the
    // deterministic rectangles request then supplies the individual pocket cards.
    static func rectify(ci: CIImage, handler: VNImageRequestHandler) -> Result? {
        let ext = ci.extent
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * ext.width, y: p.y * ext.height) }

        // Rectangles fallback — same params as the historic doc-seg-empty fallback; memoized so
        // both the empty-doc-seg path and the binder union path share a single Vision call.
        var cachedRects: [VNRectangleObservation]?
        func rectangles() -> [VNRectangleObservation] {
            if let r = cachedRects { return r }
            let rreq = VNDetectRectanglesRequest()
            rreq.minimumConfidence = 0.3
            rreq.minimumAspectRatio = 0.4
            rreq.maximumAspectRatio = 0.95
            rreq.maximumObservations = 12
            rreq.quadratureTolerance = 40
            rreq.minimumSize = 0.15
            try? handler.perform([rreq])
            let r = rreq.results ?? []
            cachedRects = r
            return r
        }

        // Doc-seg survivors: drop the confidence-0.0 whole-frame placeholder doc-seg emits when
        // it finds nothing real. If none survive, fall back to rectangles as before.
        let docReq = VNDetectDocumentSegmentationRequest()
        try? handler.perform([docReq])
        var obs = (docReq.results ?? []).filter { $0.confidence >= 0.3 }
        if obs.isEmpty { obs = rectangles() }
        guard !obs.isEmpty else { return nil }

        func aspect(_ o: VNRectangleObservation) -> Double {
            let tl = px(o.topLeft), tr = px(o.topRight), bl = px(o.bottomLeft)
            let w = hypot(tr.x - tl.x, tr.y - tl.y), h = hypot(bl.x - tl.x, bl.y - tl.y)
            let lo = min(w, h), hi = max(w, h)
            return hi > 0 ? Double(lo / hi) : 0
        }
        func pxSize(_ o: VNRectangleObservation) -> (w: CGFloat, h: CGFloat) {
            let tl = px(o.topLeft), tr = px(o.topRight), bl = px(o.bottomLeft)
            return (hypot(tr.x - tl.x, tr.y - tl.y), hypot(bl.x - tl.x, bl.y - tl.y))
        }
        func pxCenter(_ o: VNRectangleObservation) -> CGPoint {
            let c = CGPoint(x: (o.topLeft.x + o.topRight.x + o.bottomLeft.x + o.bottomRight.x) / 4,
                            y: (o.topLeft.y + o.topRight.y + o.bottomLeft.y + o.bottomRight.y) / 4)
            return px(c)
        }

        // A quad "passes the guide" iff it is card-aspect and ScanGuide.quadPasses accepts its
        // size/center for the window: orientation-neutral fit (sideways binder cards are valid),
        // size cap (a whole-page binder quad blows past 1.15×), and a minimum size (a glare
        // fragment can't outrank the real card). This is what makes a binder page resolve to
        // the aimed pocket instead of the whole grid — or a fragment of it.
        let guide = ScanGuide.cropRect(in: ext)
        let guideCenter = CGPoint(x: guide.midX, y: guide.midY)
        func passesGuide(_ o: VNRectangleObservation) -> Bool {
            guard (0.58...0.86).contains(aspect(o)) else { return false }
            let s = pxSize(o)
            return ScanGuide.quadPasses(size: CGSize(width: s.w, height: s.h),
                                        center: pxCenter(o), in: guide)
        }

        var passing = obs.filter(passesGuide)
        if passing.isEmpty {
            // Binder path: doc-seg's whole-page quad failed the FITS check. Add the deterministic
            // rectangles (the individual pocket cards) and re-apply the guide filter over the union.
            obs += rectangles()
            passing = obs.filter(passesGuide)
        }

        // Perspective-correct a chosen quad (pixel-space corners) to a natural-aspect CIImage.
        func correct(_ tl: CGPoint, _ tr: CGPoint, _ bl: CGPoint, _ br: CGPoint, _ conf: Double) -> Result? {
            guard let f = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(CIVector(cgPoint: tl), forKey: "inputTopLeft")
            f.setValue(CIVector(cgPoint: tr), forKey: "inputTopRight")
            f.setValue(CIVector(cgPoint: bl), forKey: "inputBottomLeft")
            f.setValue(CIVector(cgPoint: br), forKey: "inputBottomRight")
            guard let out = f.outputImage else { return nil }
            return Result(corrected: out, confidence: conf)
        }
        func correct(_ o: VNRectangleObservation) -> Result? {
            correct(px(o.topLeft), px(o.topRight), px(o.bottomLeft), px(o.bottomRight), Double(o.confidence))
        }

        func guideDist(_ o: VNRectangleObservation) -> Double {
            let c = pxCenter(o); return Double(hypot(c.x - guideCenter.x, c.y - guideCenter.y))
        }
        // Primary: among guide-passing candidates, nearest pixel-space center to the guide center
        // wins, confidence breaks ties (the user aims the target card at the guide center).
        if let chosen = passing.min(by: {
            (guideDist($0), -Double($0.confidence)) < (guideDist($1), -Double($1.confidence)) }) {
            return correct(chosen)
        }

        // Legacy: nearest-to-frame-center among any card-aspect quad found anywhere — a well-framed
        // single card whose quad simply overran the guide window's size cap, so it never regresses.
        func centerDist(_ o: VNRectangleObservation) -> Double {
            let cx = (o.topLeft.x + o.topRight.x + o.bottomLeft.x + o.bottomRight.x) / 4
            let cy = (o.topLeft.y + o.topRight.y + o.bottomLeft.y + o.bottomRight.y) / 4
            return Double(hypot(cx - 0.5, cy - 0.5))
        }
        let cardish = obs.filter { (0.58...0.86).contains(aspect($0)) }
        if let chosen = cardish.min(by: {
            (centerDist($0), -Double($0.confidence)) < (centerDist($1), -Double($1.confidence)) }) {
            return correct(chosen)
        }

        // Last resort: detection localized NO card-shaped quad at all — only a non-card band (e.g. a
        // glossy toploader whose glare defeats both detectors on this Simulator/CPU-Vision path;
        // doc-seg returns a horizontal strip and rectangles returns nothing — see fullframe-1557).
        // This fallback exists so "a bare card filling the
        // frame edge-to-edge never regresses"; picking the band DOES regress (it matches at 6 inliers
        // vs 87 for the frame). For a single card that fills the frame, the frame IS the card — so
        // correct the whole frame. Confidence 0: no quad was actually localized.
        return correct(CGPoint(x: ext.minX, y: ext.maxY), CGPoint(x: ext.maxX, y: ext.maxY),
                       CGPoint(x: ext.minX, y: ext.minY), CGPoint(x: ext.maxX, y: ext.minY), 0)
    }
}

/// Resolves a perspective-corrected card image (any of its 2 plausible upright rotations) to
/// the actual upright orientation, by picking whichever rotation reads best via fast OCR —
/// downstream OCR (Phase E) is not rotation-tolerant. Ported from the reference's
/// `orientUpright()`/`rotate()`/`uprightScore()`. `internal` (not `private`) so
/// `CardDetectorTests` can drive it directly with a `CIImage` — the only in-bundle card asset
/// renders to a canonical-sized plate that trips `canonicalPassthrough` before doc-seg ever
/// runs, so the full `detect()` doc-seg path isn't independently testable in-bundle.
enum OrientationNormalizer {
    /// Rotates `ci` by `degrees` about its center, then translates the result back to a
    /// positive-origin extent (rotation alone can leave negative-origin bounds).
    static func rotate(_ ci: CIImage, degrees: Int) -> CIImage {
        let r = CGFloat(degrees) * .pi / 180
        let out = ci.transformed(by: CGAffineTransform(rotationAngle: r))
        return out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
    }

    /// Scores how "upright" a rendered image is by total fast-OCR confidence — upright card
    /// text reads best (highest confidence), sideways/upside-down text scores near zero.
    static func uprightScore(_ cg: CGImage) -> Double {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        return (req.results ?? []).reduce(0.0) { $0 + Double($1.topCandidates(1).first?.confidence ?? 0) }
    }

    /// Picks the best-scoring of the 2 plausible upright rotations for `corrected` (a
    /// perspective-corrected, natural-aspect card image whose orientation is not yet
    /// resolved) and scales it to the canonical `kFPCanonW × kFPCanonH` plate size.
    static func orientUpright(_ corrected: CIImage, context: CIContext,
                              canonW: Int = Int(kFPCanonW), canonH: Int = Int(kFPCanonH)) -> CIImage? {
        // Landscape correction → the 2 candidate uprights are 90/270; portrait → 0/180.
        let candidates = corrected.extent.width > corrected.extent.height ? [90, 270] : [0, 180]
        var best: (Double, CIImage)?
        for d in candidates {
            let r = rotate(corrected, degrees: d)
            guard let cg = context.createCGImage(r, from: r.extent) else { continue }
            let s = uprightScore(cg)
            if best == nil || s > best!.0 { best = (s, r) }
        }
        guard let chosen = best?.1 else { return nil }
        return chosen.transformed(by: CGAffineTransform(
            scaleX: CGFloat(canonW) / chosen.extent.width, y: CGFloat(canonH) / chosen.extent.height))
    }
}

final class CardDetector {
    private let context: CIContext

    init(context: CIContext = CIContext()) { self.context = context }

    /// Detects a card, perspective-corrects and orientation-normalizes it, and returns the
    /// canonical BGRA plate.
    ///
    /// Passthrough for already-canonical buffers: checked FIRST, before running any Vision
    /// request — if the input `CVPixelBuffer` is already exactly `kFPCanonW × kFPCanonH`
    /// (660×920), the whole buffer is treated as the canonical plate directly: detection,
    /// perspective correction, AND orientation normalization are all skipped, BGRA bytes are
    /// read directly, and `quadConfidence` is reported as 0 (no quad was actually detected).
    /// This is production-safe: real AVCapture camera frames are never exactly 660×920
    /// (they're high-res, e.g. 1920×1080), so this branch never fires in production and
    /// `detect` proceeds to real detection there. It only exists so headless tests / a future
    /// frame-injection replay path can drive the cascade with a synthetic plate that has no
    /// printed card border for Vision to find.
    ///
    /// Size-first (rather than "fall back to passthrough only when no quad is found") is
    /// deliberate: unlike the old `VNDetectRectangles`-only cascade, `VNDetectDocumentSegmentationRequest`
    /// is a learned segmentation model, not a pure edge detector — it reliably returns a
    /// near-full-frame observation even on a blank/uniform buffer or an already-to-the-edge
    /// card image (both confirmed empirically: a solid-color 660×920 buffer yields doc-seg
    /// confidences up to ~0.97). A "return passthrough only if detection finds nothing" order
    /// would almost never take the passthrough branch on canonical-sized test buffers,
    /// breaking `ScanPipelineTests`/`ScanModelTests`. Checking size first restores the
    /// original passthrough guarantee and is equivalent in production (detection still runs
    /// on every real, non-canonical-sized frame).
    func detect(pixelBuffer: CVPixelBuffer) -> CanonicalFrame? {
        if let passthrough = Self.canonicalPassthrough(pixelBuffer) { return passthrough }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        guard let rectified = CardRectifier.rectify(ci: ci, handler: handler) else { return nil }
        guard let oriented = OrientationNormalizer.orientUpright(rectified.corrected, context: context)
        else { return nil }

        let w = Int(kFPCanonW), h = Int(kFPCanonH)
        let stride = w * 4
        var buf = [UInt8](repeating: 0, count: stride * h)
        buf.withUnsafeMutableBytes { raw in
            context.render(oriented, toBitmap: raw.baseAddress!, rowBytes: stride,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let plate = Data(buf)
        return CanonicalFrame(
            pixels: plate, width: w, height: h, bytesPerRow: stride,
            focus: ImageQuality.focus(bgra: plate, width: w, height: h, bytesPerRow: stride),
            glareCoverage: ImageQuality.glareCoverage(bgra: plate, width: w, height: h, bytesPerRow: stride),
            quadConfidence: rectified.confidence)
    }

    /// Cheap light-frame presence check (~5ms): doc-seg only — no rectification, no
    /// orientation OCR, no plate render. Canonical-sized buffers short-circuit true so
    /// synthetic-plate tests mirror canonicalPassthrough. Used by ScanPipeline on the 3-of-4
    /// frames that only feed ScanSession's grace/miss logic.
    func cardPresent(pixelBuffer: CVPixelBuffer) -> Bool {
        if CVPixelBufferGetWidth(pixelBuffer) == Int(kFPCanonW),
           CVPixelBufferGetHeight(pixelBuffer) == Int(kFPCanonH) { return true }
        let req = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([req])
        return (req.results ?? []).contains { $0.confidence >= 0.3 }
    }

    private static func canonicalPassthrough(_ pixelBuffer: CVPixelBuffer) -> CanonicalFrame? {
        let w = Int(kFPCanonW), h = Int(kFPCanonH)
        guard CVPixelBufferGetWidth(pixelBuffer) == w, CVPixelBufferGetHeight(pixelBuffer) == h,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let plate = Data(bytes: base, count: stride * h)
        return CanonicalFrame(
            pixels: plate, width: w, height: h, bytesPerRow: stride,
            focus: ImageQuality.focus(bgra: plate, width: w, height: h, bytesPerRow: stride),
            glareCoverage: ImageQuality.glareCoverage(bgra: plate, width: w, height: h, bytesPerRow: stride),
            quadConfidence: 0)
    }
}
