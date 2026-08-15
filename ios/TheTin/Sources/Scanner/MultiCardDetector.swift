import CoreImage
import Foundation
import Vision

/// How big a card is allowed to be, in units of the photograph's short side.
///
/// ⚠️ **This is the filter an aspect ratio cannot do, and the reason is a geometric coincidence.**
/// One card is 63×88 mm, so short/long = **0.716**. TWO cards side by side are 126×88, so short/long
/// = **0.698** — inside any window wide enough to accept a real card at an angle. `QuadFilter`
/// therefore accepts a card PAIR exactly as readily as a card, and measured on real device
/// photographs it did: 2 of 21 detected quads spanned two pockets, each taking one pocket and leaving
/// its neighbour's reading empty. That is what "the right cards, in the wrong order" looks like.
///
/// The way out is that **capture is always 2×2**, so a card's size in the frame is known within a
/// factor of about two whatever the binder's shape. Measured over one 3×3 page (21 quads, 4 tiles) at
/// 3024×4032: real cards had a short edge of **0.296–0.396** of the frame's short side and a long edge
/// of 0.37–0.51, while the two card-pairs had long edges of **0.68 and 0.75**, and five slivers had
/// short edges of 0.11–0.20 (three of which cleared the 300-keypoint floor, so that floor does not
/// catch them).
struct CardSizeWindow {
    /// Below this the quad is a sliver — a text band, a sleeve edge, the gap between pockets.
    var minShortSide: Double
    /// Above this it spans more than one pocket. 0.60 sits between the widest real card measured
    /// (0.51) and the narrowest card-pair (0.68).
    var maxLongSide: Double

    /// ⚠️ The floor is deliberately permissive relative to the measured card floor of 0.296, because
    /// the two errors are not symmetric: a phantom that survives usually loses its pocket to a real
    /// card on inlier count anyway, whereas a real card dropped here is a pocket that reads EMPTY and
    /// cannot be recovered.
    static let twoByTwoTile = CardSizeWindow(minShortSide: 0.22, maxLongSide: 0.60)

    func admits(quad: ScoredQuad, frameShortSide: Double) -> Bool {
        guard frameShortSide > 0 else { return true }
        let w = Double(quad.size.width), h = Double(quad.size.height)
        let short = min(w, h) / frameShortSide, long = max(w, h) / frameShortSide
        return short >= minShortSide && long <= maxLongSide
    }
}

/// One card found in a photo: where it was, and its canonical plate.
struct DetectedCell {
    let quad: CardQuad
    let plate: CanonicalFrame
    /// The upright rotation resolved for this cell. Kept so a later stage can rebuild this exact
    /// plate from `quad` without re-detecting and without holding the plate — see
    /// `MultiCardDetector.plate(quad:in:context:degrees:)`.
    let degrees: Int
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
    ///   - minShortSideFraction: what `VNDetectRectanglesRequest.minimumSize` is set to. The
    ///     single-card detector uses 0.15, which caps a photo at ~6 cards across — too strict here.
    ///   - sizeWindow: the quad's own short and long edges, as fractions of the PHOTO's short side,
    ///     outside which it is not a card. See `CardSizeWindow` — the filter an aspect ratio cannot do.
    ///     ⚠️ Defaults to nil, i.e. no assumption: a window encodes how the CALLER framed the shot, and
    ///     this detector does not know that. The binder passes `.twoByTwoTile` because its capture is
    ///     always two pockets by two.
    ///   - orienter: injected so the rotation reuse (see below) is verifiable by a test rather
    ///     than trusted by inspection — same seam pattern as `ScanStagingStore`'s injected persist
    ///     sink. Defaults to the real `OrientationNormalizer.orientUpright`; no production caller
    ///     needs to pass this.
    static func forEachCell(in ci: CIImage,
                            context: CIContext,
                            maxCards: Int = 48,
                            minShortSideFraction: Double = 0.04,
                            sizeWindow: CardSizeWindow? = nil,
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
        let frameShort = Double(min(ext.width, ext.height))
        let scored = observations.map(toPixels).filter { q in
            guard q.size.width * q.size.height < frameArea * 0.6 else { return false }
            guard let sizeWindow else { return true }
            return sizeWindow.admits(quad: q, frameShortSide: frameShort)
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
            // Real skew per cell, not 0: a binder page's outer pockets are genuinely off-axis to
            // the lens even when the phone is square to the page, and that is exactly the tilt a
            // centring measurement has to refuse.
            guard let plate = render(oriented.image, context: context,
                                     quadConfidence: q.confidence,
                                     skew: CenteringMeter.skew(q.quad),
                                     quad: q.quad, degrees: oriented.degrees) else { continue }
            // Handed over and released: the caller's `body` returns before the next plate is
            // rendered, so only one 2.4 MB plate is ever resident.
            body(DetectedCell(quad: q.quad, plate: plate, degrees: oriented.degrees))
        }
    }

    /// Rebuilds ONE plate for an already-detected quad. This is how a later stage gets a plate back
    /// after `forEachCell` released it, and it is deliberately not "detect again":
    ///
    /// - `VNDetectDocumentSegmentationRequest` is documented **in this codebase** as
    ///   non-deterministic over the same input, so re-detecting genuinely returns a different set of
    ///   cells and nothing can be matched up with what the first pass found.
    /// - Passing the already-resolved `degrees` makes `orientUpright` skip its scoring entirely —
    ///   two full renders and two Vision text passes, the bulk of `detect`'s cost.
    ///
    /// So this is one perspective-correct, one rotate and one 660×920 render, and it holds the plate
    /// only for as long as the caller does. That is what lets OCR live in the LAST stage instead of
    /// the first — which is the whole reason wishlist answers arrive before pricing answers.
    ///
    /// `quadConfidence` comes back 0: the confidence belonged to the detection, which is not being
    /// repeated. Callers that need it kept it the first time.
    static func plate(quad: CardQuad, in ci: CIImage, context: CIContext,
                      degrees: Int) -> CanonicalFrame? {
        guard let corrected = perspectiveCorrect(quad, in: ci),
              let oriented = OrientationNormalizer.orientUpright(corrected, context: context,
                                                                 preferred: degrees)
        else { return nil }
        return render(oriented.image, context: context, quadConfidence: 0,
                      skew: CenteringMeter.skew(quad), quad: quad, degrees: degrees)
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

    private static func render(_ image: CIImage, context: CIContext, quadConfidence: Double,
                               skew: Double, quad: CardQuad, degrees: Int) -> CanonicalFrame? {
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
            quadConfidence: quadConfidence, skew: skew, quad: quad, degrees: degrees)
    }
}
