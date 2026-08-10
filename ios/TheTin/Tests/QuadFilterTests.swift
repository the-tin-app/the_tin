import XCTest
@testable import TheTin

final class QuadFilterTests: XCTestCase {

    /// Axis-aligned quad helper — origin bottom-left, matching Vision's pixel space.
    private func quad(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, conf: Double = 0.9) -> ScoredQuad {
        ScoredQuad(quad: CardQuad(topLeft: CGPoint(x: x, y: y + h),
                                  topRight: CGPoint(x: x + w, y: y + h),
                                  bottomLeft: CGPoint(x: x, y: y),
                                  bottomRight: CGPoint(x: x + w, y: y)),
                   confidence: conf)
    }

    func testKeepsEveryCardShapedQuad() {
        // Nine pockets, 660x920 each, laid out 3x3 — the binder case.
        var input: [ScoredQuad] = []
        for row in 0..<3 { for col in 0..<3 {
            input.append(quad(x: CGFloat(col) * 700, y: CGFloat(row) * 960, w: 660, h: 920))
        } }
        XCTAssertEqual(QuadFilter.select(input).count, 9)
    }

    func testDropsNonCardAspects() {
        let card = quad(x: 0, y: 0, w: 660, h: 920)          // 0.717 — card
        let banner = quad(x: 0, y: 2000, w: 3000, h: 200)    // 0.067 — a glare band
        let square = quad(x: 0, y: 3000, w: 500, h: 500)     // 1.0 — not a card
        let kept = QuadFilter.select([card, banner, square])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first, card)
    }

    /// doc-seg and the rectangles request both describe the same physical card. Without a merge
    /// the same card is reported — and matched, and shown — twice.
    func testMergesDuplicateQuadsOfTheSameCard() {
        let a = quad(x: 0, y: 0, w: 660, h: 920, conf: 0.7)
        let b = quad(x: 12, y: 9, w: 655, h: 915, conf: 0.95)   // same card, jittered
        let kept = QuadFilter.select([a, b])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.confidence, 0.95, "the higher-confidence duplicate survives")
    }

    func testDoesNotMergeAdjacentDistinctCards() {
        // Two real neighbouring pockets — centres one full card-width apart.
        let left = quad(x: 0, y: 0, w: 660, h: 920)
        let right = quad(x: 700, y: 0, w: 660, h: 920)
        XCTAssertEqual(QuadFilter.select([left, right]).count, 2)
    }

    /// Pins the merge boundary itself, at the DEFAULT `mergeDistanceRatio` (0.5) — the two tests
    /// above never get near it (~0.018 and ~1.06), so a materially different implementation
    /// (fixed-pixel radius, IoU test, or any ratio from ~0.02 to ~1.0) would pass both of them
    /// while merging real detector jitter differently. Both quads are 660x920, so
    /// mergeRadius = shortSide(660) * 0.5 = 330. Centre distance here is 264 = 0.4 * 660 —
    /// inside the radius — so these must merge.
    func testMergesQuadsJustInsideDefaultMergeRadius() {
        let a = quad(x: 0, y: 0, w: 660, h: 920, conf: 0.7)
        let b = quad(x: 264, y: 0, w: 660, h: 920, conf: 0.95)   // centre distance 264 < 330
        let kept = QuadFilter.select([a, b])
        XCTAssertEqual(kept.count, 1)
    }

    /// Same boundary, other side. Centre distance here is 396 = 0.6 * 660 — outside the 330
    /// radius — so these must NOT merge.
    func testDoesNotMergeQuadsJustOutsideDefaultMergeRadius() {
        let a = quad(x: 0, y: 0, w: 660, h: 920)
        let b = quad(x: 396, y: 0, w: 660, h: 920)   // centre distance 396 > 330
        let kept = QuadFilter.select([a, b])
        XCTAssertEqual(kept.count, 2)
    }

    func testCapIsHighestConfidenceFirstNotArbitrary() {
        var input: [ScoredQuad] = []
        for i in 0..<10 {
            input.append(quad(x: CGFloat(i) * 700, y: 0, w: 660, h: 920, conf: Double(i) / 10.0))
        }
        let kept = QuadFilter.select(input, maxCards: 3)
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(Set(kept.map(\.confidence)), [0.9, 0.8, 0.7])
    }

    func testEmptyInputIsEmptyOutput() {
        XCTAssertTrue(QuadFilter.select([]).isEmpty)
    }

    // MARK: - CardSizeWindow: the filter an aspect ratio cannot do

    /// A quad with the given edge lengths in pixels, axis-aligned.
    private func quad(_ w: Double, _ h: Double) -> ScoredQuad {
        ScoredQuad(quad: CardQuad(topLeft: CGPoint(x: 0, y: h), topRight: CGPoint(x: w, y: h),
                                  bottomLeft: .zero, bottomRight: CGPoint(x: w, y: 0)),
                   confidence: 1)
    }

    /// ⚠️ **The coincidence.** One card is 63×88 mm → short/long 0.716. TWO side by side are 126×88 →
    /// short/long 0.698. Both sit inside any aspect window wide enough to accept a real card at an
    /// angle, so `select`'s aspect filter cannot tell them apart — and measured on a real 3×3 page, 2 of
    /// 21 detected quads spanned two pockets, each taking one pocket and leaving its neighbour's
    /// reading empty. That is what "the right cards, in the wrong order" looked like.
    func testTheAspectFilterCannotSeparateACardFromACardPair() {
        let one = quad(63, 88), pair = quad(126, 88)
        XCTAssertEqual(one.aspect, 63.0 / 88.0, accuracy: 0.001)
        XCTAssertEqual(pair.aspect, 88.0 / 126.0, accuracy: 0.001)
        // Both inside select()'s default window — this is the bug, asserted so it stays understood.
        for q in [one, pair] { XCTAssertTrue((0.58...0.86).contains(q.aspect), "\(q.aspect)") }
    }

    /// …and the size window can, because capture is always 2×2 so a card's size in the frame is known
    /// within about a factor of two. Numbers measured over one real 3×3 page at 3024×4032.
    func testTheSizeWindowSeparatesThem() {
        let frameShort = 3024.0
        let window = CardSizeWindow.twoByTwoTile
        // Real cards measured 0.296-0.396 of the frame's short side on the short edge.
        for shortEdge in [0.296, 0.34, 0.396] {
            let q = quad(shortEdge * frameShort, shortEdge * frameShort / 0.716)
            XCTAssertTrue(window.admits(quad: q, frameShortSide: frameShort), "card at \(shortEdge)")
        }
        // The two card-pairs measured: long edges of 0.68 and 0.75 of the frame's short side.
        for longEdge in [0.68, 0.75] {
            let q = quad(longEdge * frameShort, longEdge * frameShort * 0.698)
            XCTAssertFalse(window.admits(quad: q, frameShortSide: frameShort), "pair at \(longEdge)")
        }
        // Five slivers measured, short edges 0.11-0.20 — three of which cleared the keypoint floor.
        for shortEdge in [0.106, 0.144, 0.202] {
            let q = quad(shortEdge * frameShort, shortEdge * frameShort / 0.75)
            XCTAssertFalse(window.admits(quad: q, frameShortSide: frameShort), "sliver at \(shortEdge)")
        }
    }

    /// ⚠️ The floor is permissive on purpose, and the asymmetry is the reason: a phantom that survives
    /// usually loses its pocket to a real card on inlier count, but a real card dropped here is a
    /// pocket that reads EMPTY and cannot be recovered.
    func testTheFloorLeavesHeadroomBelowTheMeasuredCardFloor() {
        XCTAssertLessThan(CardSizeWindow.twoByTwoTile.minShortSide, 0.296)
        XCTAssertGreaterThan(CardSizeWindow.twoByTwoTile.minShortSide, 0.202)
        XCTAssertGreaterThan(CardSizeWindow.twoByTwoTile.maxLongSide, 0.51)   // widest real card
        XCTAssertLessThan(CardSizeWindow.twoByTwoTile.maxLongSide, 0.68)      // narrowest card pair
    }

    func testAZeroFrameAdmitsRatherThanDropsEverything() {
        XCTAssertTrue(CardSizeWindow.twoByTwoTile.admits(quad: quad(100, 140), frameShortSide: 0))
    }
}
