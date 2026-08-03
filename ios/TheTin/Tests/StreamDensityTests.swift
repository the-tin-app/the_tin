import XCTest
@testable import TheTin

final class StreamDensityTests: XCTestCase {

    /// A trailing partial page is a real page — 5 cards at 2×2 is two pages, not one.
    func testPageCountRoundsUp() {
        XCTAssertEqual(StreamDensity.four.pageCount(cardCount: 5), 2)
        XCTAssertEqual(StreamDensity.four.pageCount(cardCount: 8), 2)
        XCTAssertEqual(StreamDensity.four.pageCount(cardCount: 9), 3)
        XCTAssertEqual(StreamDensity.one.pageCount(cardCount: 9), 9)
        XCTAssertEqual(StreamDensity.four.pageCount(cardCount: 0), 0)
    }

    /// The last page is short, not padded, and never reads past the array.
    func testCardRangeClampsTheLastPage() {
        XCTAssertEqual(StreamDensity.four.cardRange(page: 0, cardCount: 5), 0..<4)
        XCTAssertEqual(StreamDensity.four.cardRange(page: 1, cardCount: 5), 4..<5)
        // A page index past the end is empty, not a crash.
        XCTAssertEqual(StreamDensity.four.cardRange(page: 9, cardCount: 5), 5..<5)
    }

    /// Switching density keeps the card you were looking at on screen. Card 40 in 1-up is page
    /// 40; at 2×2 that card lives on page 10. Without the remap the deck jumps to card 160 and
    /// reads as having lost your place.
    func testRemapKeepsYourPlaceAcrossADensityChange() {
        XCTAssertEqual(StreamDensity.four.remapPage(40, from: .one), 10)
        XCTAssertEqual(StreamDensity.one.remapPage(10, from: .four), 40)
        XCTAssertEqual(StreamDensity.four.remapPage(0, from: .one), 0)
        // Mid-page in grid mode lands on the page holding that page's FIRST card.
        XCTAssertEqual(StreamDensity.four.remapPage(41, from: .one), 10)
    }

    /// ⚠️ Prefetch is counted in PAGES. At 2×2 with 2 pages ahead that is 8 images, not the 20
    /// the old per-card constant of 5 would have produced against a 4-deep download gate.
    func testPrefetchIsPageDenominatedAndShallow() {
        XCTAssertEqual(StreamDensity.four.prefetchRange(page: 0, cardCount: 100), 0..<8)
        XCTAssertEqual(StreamDensity.one.prefetchRange(page: 0, cardCount: 100), 0..<2)
        // Never reads past the end.
        XCTAssertEqual(StreamDensity.four.prefetchRange(page: 24, cardCount: 100), 96..<100)
        XCTAssertEqual(StreamDensity.four.prefetchRange(page: 25, cardCount: 100), 100..<100)
    }

    /// The 1-up case must keep working exactly as before — one card per page.
    func testOneUpIsUnchanged() {
        XCTAssertEqual(StreamDensity.one.pageSize, 1)
        XCTAssertEqual(StreamDensity.one.cardRange(page: 7, cardCount: 100), 7..<8)
        XCTAssertEqual(StreamDensity.one.columns, 1)
    }
}
