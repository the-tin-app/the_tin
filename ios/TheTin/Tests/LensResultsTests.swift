import XCTest
@testable import TheTin

final class LensResultsTests: XCTestCase {

    private let photoId = UUID()

    private func cell(_ cardId: String?, wishlist: Bool = false) -> LensCell {
        let q = CardQuad(topLeft: .zero, topRight: .zero, bottomLeft: .zero, bottomRight: .zero)
        return LensCell(quad: q, onWishlist: wishlist,
                        state: cardId.map { .identified(cardId: $0, inliers: 40) } ?? .noMatch)
    }

    func testOnlyIdentifiedCellsBecomeRows() {
        let rows = LensResults.rows(photos: [photoId: [cell("a"), cell(nil)]],
                                    prices: [:], owned: [])
        XCTAssertEqual(rows.map(\.cardId), ["a"])
    }

    func testWishlistHitsLeadRegardlessOfPrice() {
        let rows = LensResults.rows(
            photos: [photoId: [cell("cheap", wishlist: true), cell("expensive")]],
            prices: ["cheap": 3, "expensive": 200], owned: [])
        XCTAssertEqual(rows.map(\.cardId), ["cheap", "expensive"])
    }

    func testNonWishlistRowsSortByPriceDescending() {
        let rows = LensResults.rows(
            photos: [photoId: [cell("mid"), cell("top"), cell("low")]],
            prices: ["mid": 20, "top": 200, "low": 2], owned: [])
        XCTAssertEqual(rows.map(\.cardId), ["top", "mid", "low"])
    }

    func testUnpricedRowsSortLastNotFirst() {
        let rows = LensResults.rows(photos: [photoId: [cell("unpriced"), cell("priced")]],
                                    prices: ["priced": 5], owned: [])
        XCTAssertEqual(rows.map(\.cardId), ["priced", "unpriced"])
    }

    func testHideOwnedRemovesOwnedCards() {
        let rows = LensResults.rows(photos: [photoId: [cell("have"), cell("want")]],
                                    prices: [:], owned: ["have"])
        let filtered = LensResults.apply(LensFilter(hideOwned: true), to: rows)
        XCTAssertEqual(filtered.map(\.cardId), ["want"])
    }

    func testMaxPriceExcludesUnpricedCards() {
        let rows = LensResults.rows(photos: [photoId: [cell("cheap"), cell("unpriced")]],
                                    prices: ["cheap": 3], owned: [])
        let filtered = LensResults.apply(LensFilter(maxPriceUsd: 5), to: rows)
        XCTAssertEqual(filtered.map(\.cardId), ["cheap"],
                       "an unknown price is not evidence of a low price")
    }

    func testWishlistOnlyKeepsHits() {
        let rows = LensResults.rows(photos: [photoId: [cell("a", wishlist: true), cell("b")]],
                                    prices: [:], owned: [])
        XCTAssertEqual(LensResults.apply(LensFilter(wishlistOnly: true), to: rows).map(\.cardId),
                       ["a"])
    }

    func testFiltersCompose() {
        let rows = LensResults.rows(
            photos: [photoId: [cell("a", wishlist: true), cell("b", wishlist: true), cell("c")]],
            prices: ["a": 3, "b": 90, "c": 1], owned: ["b"])
        let filtered = LensResults.apply(
            LensFilter(wishlistOnly: true, hideOwned: true, maxPriceUsd: 10), to: rows)
        XCTAssertEqual(filtered.map(\.cardId), ["a"])
    }
}
