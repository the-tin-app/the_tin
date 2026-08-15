import CoreGraphics
import Foundation

/// `Task 3` (a later task) was going to add this same conformance for its own needs; this task
/// needs it first (`ScoredQuad: Equatable` embeds a `CardQuad`), so it lives here instead — don't
/// duplicate it when Task 3 lands.
extension CardQuad: Equatable {
    static func == (lhs: CardQuad, rhs: CardQuad) -> Bool {
        lhs.topLeft == rhs.topLeft && lhs.topRight == rhs.topRight &&
        lhs.bottomLeft == rhs.bottomLeft && lhs.bottomRight == rhs.bottomRight
    }
}

/// A detected card-shaped quad with the detector's confidence in it. Plain values — no Vision
/// types — so every selection decision below is unit-testable. `MultiCardDetector` maps Vision
/// observations into these and does nothing else clever.
struct ScoredQuad: Equatable {
    let quad: CardQuad
    let confidence: Double

    var center: CGPoint {
        CGPoint(x: (quad.topLeft.x + quad.topRight.x + quad.bottomLeft.x + quad.bottomRight.x) / 4,
                y: (quad.topLeft.y + quad.topRight.y + quad.bottomLeft.y + quad.bottomRight.y) / 4)
    }

    var size: CGSize {
        CGSize(width: hypot(quad.topRight.x - quad.topLeft.x, quad.topRight.y - quad.topLeft.y),
               height: hypot(quad.bottomLeft.x - quad.topLeft.x, quad.bottomLeft.y - quad.topLeft.y))
    }

    /// Short side over long side — orientation-neutral, so a sideways card scores the same as an
    /// upright one. A trading card is ~0.717.
    var aspect: Double {
        let lo = min(size.width, size.height), hi = max(size.width, size.height)
        return hi > 0 ? Double(lo / hi) : 0
    }
}

/// Turns the raw union of both Vision detectors into the set of distinct cards in a photo.
///
/// The single-card scanner solves this by keeping whichever quad sits nearest the guide window
/// (`CardRectifier.rectify`). The lens wants all of them, which introduces one problem the
/// single-card path never had: `VNDetectDocumentSegmentationRequest` and `VNDetectRectanglesRequest`
/// are unioned, and both describe the same physical card — so duplicates must be merged or every
/// card is reported twice.
enum QuadFilter {
    /// - Parameters:
    ///   - maxCards: hard cap. Ordered by confidence so the cap drops the *least* certain quads
    ///     rather than an arbitrary tail. `LIMIT` without a meaningful order is a selection
    ///     criterion in disguise — this project has shipped that bug before.
    ///   - mergeDistanceRatio: two quads are the same card when their centres are closer than this
    ///     fraction of the smaller quad's short side. 0.5 merges the jitter between two detectors
    ///     while leaving genuinely adjacent pockets (a full card-width apart) separate.
    static func select(_ quads: [ScoredQuad],
                       maxCards: Int = 48,
                       minAspect: Double = 0.58,
                       maxAspect: Double = 0.86,
                       mergeDistanceRatio: Double = 0.5) -> [ScoredQuad] {
        let cardish = quads.filter { (minAspect...maxAspect).contains($0.aspect) }
        // Confidence-descending, so a merge always keeps the better-evidenced duplicate and the
        // cap always drops the worst.
        let ranked = cardish.sorted { $0.confidence > $1.confidence }

        var kept: [ScoredQuad] = []
        for candidate in ranked {
            let shortSide = min(candidate.size.width, candidate.size.height)
            let mergeRadius = shortSide * CGFloat(mergeDistanceRatio)
            let isDuplicate = kept.contains { existing in
                hypot(existing.center.x - candidate.center.x,
                      existing.center.y - candidate.center.y) < mergeRadius
            }
            if !isDuplicate { kept.append(candidate) }
            if kept.count == maxCards { break }
        }
        return kept
    }
}
