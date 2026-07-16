import CoreGraphics

/// Single source of truth for the scan framing guide: the central card-shaped window of the
/// camera frame the pipeline actually analyzes. ScanView draws the visual guide the user aims
/// with; detection runs on the FULL frame (cropping before Vision was tried and abandoned — see
/// CardDetector.swift's CardRectifier.rectify comment block) and this rect is instead the
/// SELECTION window: a candidate quad is only chosen if it is card-aspect, centered inside this
/// rect, and fits within it (×1.15). A 9-pocket binder page's whole-page quad fails the fit
/// check and is rejected in favor of the aimed pocket.
enum ScanGuide {
    /// Pokémon card aspect (63×88mm) — matches ScanView's guide RoundedRectangle.
    static let cardAspect: CGFloat = 0.717

    /// Largest centered card-aspect rect fitting 92% of the frame, expanded by a 10% margin
    /// (detection tolerates loose framing; the margin keeps slightly-off aim inside the crop),
    /// clamped to the frame.
    static func cropRect(in extent: CGRect) -> CGRect {
        var w = extent.width * 0.92
        var h = w / cardAspect
        if h > extent.height * 0.92 { h = extent.height * 0.92; w = h * cardAspect }
        w = min(w * 1.10, extent.width)
        h = min(h * 1.10, extent.height)
        return CGRect(x: extent.midX - w / 2, y: extent.midY - h / 2, width: w, height: h)
            .intersection(extent)
    }

    /// Whether a detected quad (pixel-space size + center) is a plausible aimed card for the
    /// guide window. Card aspect is the caller's check; here: center inside the window, an
    /// orientation-NEUTRAL fit (short side vs short side, long vs long — a card lying sideways
    /// in a binder pocket is as valid as an upright one; OrientationNormalizer squares up the
    /// plate later), and a minimum size (≥40% of the window's long side) so a small card-aspect
    /// glare fragment can never outrank the real card. Both requirements come from the
    /// 2026-07-15 on-device binder failure: an orientation-naive w/h fit rejected every
    /// sideways card quad (~1387×1006 vs a portrait window), letting a 435×309 fragment win —
    /// a zoomed garbage plate the minFocus gate then silently ate on 7/9 cards.
    static func quadPasses(size: CGSize, center: CGPoint, in guide: CGRect) -> Bool {
        guard guide.contains(center) else { return false }
        let qs = min(size.width, size.height), ql = max(size.width, size.height)
        let gs = min(guide.width, guide.height), gl = max(guide.width, guide.height)
        return qs <= gs * 1.15 && ql <= gl * 1.15 && ql >= gl * 0.4
    }
}
