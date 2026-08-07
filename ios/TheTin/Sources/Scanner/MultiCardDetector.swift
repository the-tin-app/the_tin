import CoreImage
import Foundation
import Vision

/// One card found in a photo: where it was, and its canonical plate.
struct DetectedCell {
    let quad: CardQuad
    let plate: CanonicalFrame
}

/// A whole photo → every card in it, each as a canonical 660×920 plate.
///
/// This is the lens counterpart to `CardDetector.detect`, which deliberately resolves a frame to
/// exactly ONE card (the one nearest the guide window). The two do not share a code path on
/// purpose: `CardDetector` is gated by `LabeledPhotoAccuracyTests` at 51/64 auto-lock with zero
/// wrong-locks, and nothing here is allowed to move that number.
enum MultiCardDetector {

    /// Detects every card in `ci` and hands each one to `body`, which **releases** it before the
    /// next is rendered — at most ONE plate is resident at a time.
    ///
    /// ⚠️ Streaming is the whole interface, and it is not a micro-optimisation. A plate is
    /// 660×920×4 = 2,428,800 B and `maxCards` is 48, so an array-returning form peaks at ~117 MB
    /// of plates before its caller sees a single one — on top of the decoded source photo and the
    /// CIContext's caches. Jetsam samples the peak, is uncatchable by Crashlytics (SIGKILL leaves
    /// no report at all), and has already killed this app once. There was such a form here; it had
    /// no production callers and existed only for the tests, which is a live-looking API whose one
    /// purpose is the crash the rest of this file exists to avoid. The tests collect for
    /// themselves now.
    ///
    /// - Parameters:
    ///   - minShortSideFraction: a quad's short side must be at least this fraction of the photo's
    ///     short side. The single-card detector uses `VNDetectRectanglesRequest.minimumSize = 0.15`,
    ///     which caps a photo at ~6 cards across — far too strict here. 0.04 is the starting point
    ///     and is calibrated against real fixtures in Task 8.
    ///   - orienter: injected so the rotation reuse (see below) is verifiable by a test rather
    ///     than trusted by inspection — same seam pattern as `ScanStagingStore`'s injected persist
    ///     sink. Defaults to the real `OrientationNormalizer.orientUpright`; no production caller
    ///     needs to pass this.
    static func forEachCell(in ci: CIImage,
                            context: CIContext,
                            maxCards: Int = 48,
                            minShortSideFraction: Double = 0.04,
                            orienter: (CIImage, CIContext, Int?) -> (image: CIImage, degrees: Int)? = { corrected, context, preferred in
                                OrientationNormalizer.orientUpright(corrected, context: context, preferred: preferred)
                            },
                            _ body: (DetectedCell) -> Void) {
        let ext = ci.extent
        guard ext.width > 0, ext.height > 0 else { return }
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])

        func toPixels(_ o: VNRectangleObservation) -> ScoredQuad {
            func px(_ p: CGPoint) -> CGPoint {
                CGPoint(x: ext.minX + p.x * ext.width, y: ext.minY + p.y * ext.height)
            }
            return ScoredQuad(quad: CardQuad(topLeft: px(o.topLeft), topRight: px(o.topRight),
                                             bottomLeft: px(o.bottomLeft), bottomRight: px(o.bottomRight)),
                              confidence: Double(o.confidence))
        }

        // Both detectors, unioned. doc-seg is robust to low contrast and glare but returns few
        // observations; the rectangles request is deterministic and returns many. `QuadFilter`
        // merges the duplicates this union necessarily produces.
        var observations: [VNRectangleObservation] = []

        let docReq = VNDetectDocumentSegmentationRequest()
        try? handler.perform([docReq])
        observations += (docReq.results ?? []).filter { $0.confidence >= 0.3 }

        let rectReq = VNDetectRectanglesRequest()
        rectReq.minimumConfidence = 0.3
        rectReq.minimumAspectRatio = 0.4
        rectReq.maximumAspectRatio = 0.95
        rectReq.maximumObservations = Int(maxCards)          // 12 in the single-card path
        rectReq.quadratureTolerance = 40
        rectReq.minimumSize = Float(minShortSideFraction)    // 0.15 in the single-card path
        try? handler.perform([rectReq])
        observations += rectReq.results ?? []

        guard !observations.isEmpty else { return }

        // A quad covering essentially the whole frame is the page/case itself, not a card.
        let frameArea = ext.width * ext.height
        let scored = observations.map(toPixels).filter { q in
            q.size.width * q.size.height < frameArea * 0.6
        }
        let selected = QuadFilter.select(scored, maxCards: maxCards)
        guard !selected.isEmpty else { return }

        // Orientation is resolved ONCE per orientation class and reused. `orientUpright` costs two
        // full-resolution renders plus two Vision text passes per call — the bulk of the
        // ~1,150 ms `detect` measured on an A10. Every card in one binder page or one case is
        // the same way up; a sideways one comes back unmatched, not wrong.
        //
        // ⚠️ TWO hints, not one. `orientUpright` only honours `preferred` when it is one of the
        // candidates for that image, and the candidates are [90, 270] for a landscape-extent
        // correction against [0, 180] for a portrait one. A single shared hint therefore degrades
        // silently: one landscape-ish quad mid-page — an occluded card, a card lying sideways in a
        // case, a glare band that clears the aspect filter — poisons the hint for every remaining
        // portrait cell, and each one pays the full scoring again. Keyed by class, a mixed page
        // costs two scorings instead of one per cell.
        var rotationByClass: [Bool: Int] = [:]
        for q in selected {
            guard let corrected = perspectiveCorrect(q.quad, in: ci) else { continue }
            let isLandscape = corrected.extent.width > corrected.extent.height
            guard let oriented = orienter(corrected, context, rotationByClass[isLandscape])
            else { continue }
            rotationByClass[isLandscape] = oriented.degrees
            guard let plate = render(oriented.image, context: context,
                                     quadConfidence: q.confidence) else { continue }
            // Handed over and released: the caller's `body` returns before the next plate is
            // rendered, so only one 2.4 MB plate is ever resident.
            body(DetectedCell(quad: q.quad, plate: plate))
        }
    }

    /// Perspective-corrects `quad` out of `ci` to a natural-aspect image (orientation not yet
    /// resolved). This file names the two halves `perspectiveCorrect`/`render` instead of one
    /// combined `rectify`, mirroring `CardRectifier`'s own internal `correct(...)` rather than
    /// `PerspectiveCorrector.canonicalBGRA` — that helper scales straight to the canonical W×H,
    /// which throws away the natural-aspect extent `OrientationNormalizer.orientUpright` needs to
    /// tell portrait from landscape candidates.
    private static func perspectiveCorrect(_ quad: CardQuad, in ci: CIImage) -> CIImage? {
        guard let f = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(CIVector(cgPoint: quad.topLeft), forKey: "inputTopLeft")
        f.setValue(CIVector(cgPoint: quad.topRight), forKey: "inputTopRight")
        f.setValue(CIVector(cgPoint: quad.bottomLeft), forKey: "inputBottomLeft")
        f.setValue(CIVector(cgPoint: quad.bottomRight), forKey: "inputBottomRight")
        return f.outputImage
    }

    private static func render(_ image: CIImage, context: CIContext,
                               quadConfidence: Double) -> CanonicalFrame? {
        let w = Int(kFPCanonW), h = Int(kFPCanonH), stride = w * 4
        var buf = [UInt8](repeating: 0, count: stride * h)
        buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: stride,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let plate = Data(buf)
        return CanonicalFrame(
            pixels: plate, width: w, height: h, bytesPerRow: stride,
            focus: ImageQuality.focus(bgra: plate, width: w, height: h, bytesPerRow: stride),
            glareCoverage: ImageQuality.glareCoverage(bgra: plate, width: w, height: h,
                                                      bytesPerRow: stride),
            quadConfidence: quadConfidence)
    }
}
