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
}
