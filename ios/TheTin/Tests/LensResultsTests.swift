import XCTest
@testable import TheTin

final class LensResultsTests: XCTestCase {

    private let photoId = UUID()

    private func cell(_ cardId: String?, wishlist: Bool = false) -> LensCell {
        let q = CardQuad(topLeft: .zero, topRight: .zero, bottomLeft: .zero, bottomRight: .zero)
        return LensCell(quad: q, onWishlist: wishlist,
                        state: cardId.map { .identified(cardId: $0, inliers: 40) } ?? .noMatch)
    }

    /// Pass A has hit; pass B has not run yet, so `state` is still `.pending`.
    private func passAHit(_ cardId: String) -> LensCell {
        let q = CardQuad(topLeft: .zero, topRight: .zero, bottomLeft: .zero, bottomRight: .zero)
        return LensCell(quad: q, onWishlist: true, wishlistCardId: cardId, state: .pending)
    }

    /// The feature's headline. All of pass A runs before any pass B, so for the whole of that
    /// phase a wishlist hit's ONLY card id is the one pass A found — and without it the user gets
    /// "3 cards from your wishlist" over an empty list, with no way to see which cards.
    func testAPassAHitProducesARowBeforePassBHasRun() {
        let rows = LensResults.rows(photos: [photoId: [passAHit("wanted"), cell(nil)]],
                                    prices: [:], owned: [])
        XCTAssertEqual(rows.map(\.cardId), ["wanted"])
    }

    /// During the pass-A phase every row is a wishlist hit, so how hits order against EACH OTHER
    /// is the primary ordering the user sees. Price descending, same as everything else — pinned
    /// because a mutant that sorted the wishlist bucket by card id passed every other test here.
    func testTwoWishlistHitsOrderByPriceDescending() {
        let rows = LensResults.rows(photos: [photoId: [passAHit("cheap"), passAHit("dear")]],
                                    prices: ["cheap": 4, "dear": 60], owned: [])
        XCTAssertEqual(rows.map(\.cardId), ["dear", "cheap"])
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
