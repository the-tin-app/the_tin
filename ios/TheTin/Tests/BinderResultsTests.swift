import XCTest
@testable import TheTin

/// The list's sorts and filters. Pure — the whole point of `BinderResults` being a free function.
final class BinderResultsTests: XCTestCase {

    private func slot(_ page: Int, _ row: Int, _ col: Int) -> BinderSlot {
        BinderSlot(page: page, row: row, col: col)
    }

    private func card(_ id: String, _ name: String) -> CardRecord {
        CardRecord(id: id, setId: "set", number: "1", name: name, hp: nil, types: [],
                   rarity: nil, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }

    /// Four pockets: a cheap wanted card, an expensive unwanted one, an owned one, one with no price.
    private func scan() -> BinderScan {
        var s = BinderScan(shape: .default, createdAt: Date())
        s.put(BinderSlotEntry(slot: slot(0, 2, 2), cardId: "want", onWishlist: true))
        s.put(BinderSlotEntry(slot: slot(0, 0, 0), cardId: "dear"))
        s.put(BinderSlotEntry(slot: slot(0, 0, 1), cardId: "owned"))
        s.put(BinderSlotEntry(slot: slot(1, 0, 0), cardId: "unpriced"))
        s.put(BinderSlotEntry(slot: slot(0, 1, 0)))     // unresolved — no card
        return s
    }

    private func rows(_ filter: BinderFilter = BinderFilter()) -> [BinderRow] {
        BinderResults.apply(filter, to: BinderResults.rows(
            scan(),
            prices: ["want": 3, "dear": 200, "owned": 12],
            cards: ["want": card("want", "Bulbasaur"), "dear": card("dear", "Zapdos"),
                    "owned": card("owned", "Alakazam"), "unpriced": card("unpriced", "Machop")],
            sets: ["want": "Base", "dear": "Jungle", "owned": "Base", "unpriced": "Fossil"],
            owned: ["owned"]))
    }

    /// An unresolved pocket with nothing to name gets no row: that is not information, and the grid is
    /// where it is visible and tappable.
    func testOnlyNameablePocketsBecomeRows() {
        XCTAssertEqual(rows().count, 4)
    }

    /// ⚠️ An unconfirmed wishlist candidate DOES get a row, flagged. Both halves matter: "is anything I
    /// want here" is the question this feature exists to answer and must survive pass A being demoted out
    /// of the answer — and a row that looks identical to a confirmed one is exactly the confident wrong
    /// answer the demotion was for.
    func testAnUnconfirmedWishlistCandidateGetsAFlaggedRow() throws {
        var s = BinderScan(shape: .default, createdAt: Date())
        var e = BinderSlotEntry(slot: slot(0, 0, 0))
        e.wishlistCandidate = "want"
        e.onWishlist = true
        e.options = ["want"]
        s.put(e)
        let out = BinderResults.rows(s, prices: ["want": 3], cards: ["want": card("want", "Bulbasaur")],
                                     sets: [:], owned: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].cardId, "want")
        XCTAssertFalse(out[0].confirmed, "a guess must not present as an identification")
        XCTAssertTrue(out[0].onWishlist)
    }

    /// Wishlist hits lead unconditionally. Burying a $3 wanted card under a $200 one the user does not
    /// want inverts the whole feature.
    func testWishlistFirstBeatsPrice() {
        XCTAssertEqual(rows().map(\.cardId), ["want", "dear", "owned", "unpriced"])
    }

    /// ⚠️ An unknown price is not a cheap one. It must never head a "low to high" list, where it would
    /// look like the bargain of the binder.
    func testUnpricedNeverLeadsLowToHigh() {
        var f = BinderFilter(); f.sort = .priceLowToHigh
        XCTAssertEqual(rows(f).map(\.cardId), ["want", "owned", "dear", "unpriced"])
    }

    func testPriceHighToLow() {
        var f = BinderFilter(); f.sort = .priceHighToLow
        XCTAssertEqual(rows(f).map(\.cardId), ["dear", "owned", "want", "unpriced"])
    }

    func testNameAndSetSorts() {
        var f = BinderFilter(); f.sort = .name
        XCTAssertEqual(rows(f).map(\.name), ["Alakazam", "Bulbasaur", "Machop", "Zapdos"])
        f.sort = .set
        XCTAssertEqual(rows(f).map(\.setName), ["Base", "Base", "Fossil", "Jungle"])
    }

    func testSlotOrderIsPageThenReadingOrder() {
        var f = BinderFilter(); f.sort = .slotOrder
        XCTAssertEqual(rows(f).map(\.cardId), ["dear", "owned", "want", "unpriced"])
    }

    /// ⚠️ Every ordering ends in slot order. Two cards at the same price in an unstable order reshuffle
    /// under the user's thumb as later pages resolve, which in a shop reads as the app losing its place.
    func testEqualKeysBreakTiesOnSlotSoTheListNeverReshuffles() {
        var s = BinderScan(shape: .default, createdAt: Date())
        s.put(BinderSlotEntry(slot: slot(0, 2, 2), cardId: "b"))
        s.put(BinderSlotEntry(slot: slot(0, 0, 0), cardId: "a"))
        let same = ["a": 5.0, "b": 5.0]
        for sort in BinderSort.allCases {
            var f = BinderFilter(); f.sort = sort
            let out = BinderResults.apply(f, to: BinderResults.rows(s, prices: same, cards: [:],
                                                                    sets: [:], owned: []))
            XCTAssertEqual(out.map(\.cardId), ["a", "b"], "\(sort)")
        }
    }

    func testFilters() {
        var f = BinderFilter()
        f.wishlistOnly = true
        XCTAssertEqual(rows(f).map(\.cardId), ["want"])

        f = BinderFilter(); f.hideOwned = true
        XCTAssertFalse(rows(f).contains { $0.cardId == "owned" })

        f = BinderFilter(); f.setName = "Base"
        XCTAssertEqual(Set(rows(f).map(\.cardId)), ["want", "owned"])
    }

    /// An unknown price is NOT evidence of a low price — a "$5 and under" filter that showed unpriced
    /// cards would promise a bargain the app cannot see.
    func testAPriceCapExcludesUnpricedCards() {
        var f = BinderFilter(); f.maxPriceUsd = 5
        XCTAssertEqual(rows(f).map(\.cardId), ["want"])
    }
}
