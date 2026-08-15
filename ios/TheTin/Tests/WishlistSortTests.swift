import XCTest
@testable import TheTin

final class WishlistSortTests: XCTestCase {
    private static func card(_ id: String, _ name: String) -> CardRecord {
        CardRecord(id: id, setId: "s", number: "1", name: name, hp: nil, types: [], rarity: nil,
                   artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }
    private let cards = [card("a", "Abra"), card("b", "Bulbasaur"), card("c", "Charizard")]

    func testPriorityThenPriceDesc() {
        let entries: [String: WantEntry] = [
            "a": WantEntry(priority: .normal), "b": WantEntry(priority: .high),
            "c": WantEntry(priority: .high)]
        let prices = ["b": 5.0, "c": 50.0, "a": 999.0]
        let out = WishlistGrid.sorted(cards: cards, entries: entries, prices: prices,
                                      setDates: [:], by: .priority)
        // High first (c before b by price desc), then normal (a).
        XCTAssertEqual(out.map(\.id), ["c", "b", "a"])
    }

    func testOnSaleSurfacesAtOrUnderTargetDeepestFirst() {
        let entries: [String: WantEntry] = [
            "a": WantEntry(targetUsd: 10),   // price 8 → on sale, -2
            "b": WantEntry(targetUsd: 10),   // price 4 → on sale, -6 (deeper)
            "c": WantEntry(targetUsd: 10)]   // price 20 → not on sale
        let prices = ["a": 8.0, "b": 4.0, "c": 20.0]
        let out = WishlistGrid.sorted(cards: cards, entries: entries, prices: prices,
                                      setDates: [:], by: .onSale)
        XCTAssertEqual(Array(out.prefix(2)).map(\.id), ["b", "a"])   // deepest discount first
        XCTAssertEqual(out.last?.id, "c")
        XCTAssertTrue(WishlistGrid.isOnSale(cards[0], entry: entries["a"], price: 8.0))
        XCTAssertFalse(WishlistGrid.isOnSale(cards[2], entry: entries["c"], price: 20.0))
    }
}

extension WishlistSortTests {
    /// Reuses the file's existing `private static func card(_:_:)` (line 5) rather than
    /// defining a second factory — `private` is file-scoped in Swift, so an extension in
    /// the same file can call it.
    private func card(_ id: String) -> CardRecord { Self.card(id, id) }

    /// `addedAt` is the tie-break now that hunts have no deadline, so it's the only time field
    /// these cases need.
    private func hunting(target: Double, addedAt: Date = .distantPast) -> WantEntry {
        WantEntry(priority: .grail, targetUsd: target, notes: "", addedAt: addedAt,
                  hunt: Hunt(minCondition: .hp))
    }

    /// Sorted by proximity to budget (market/target ascending), so the top row is the card
    /// most likely to be buyable today — not the cheapest, and not alphabetical.
    func testHuntSortLeadsWithClosestToBudget() {
        let entries = ["far": hunting(target: 100),   // 90/100 = 0.90
                       "near": hunting(target: 100)]  // 60/100 = 0.60
        let sorted = WishlistGrid.huntSorted(cards: [card("far"), card("near")],
                                             entries: entries,
                                             prices: ["far": 90, "near": 60])
        XCTAssertEqual(sorted.map(\.id), ["near", "far"])
    }

    /// A wanted card that isn't hunted stays wanted — it just isn't in this scope. Hunts no
    /// longer expire, so "not hunting" means exactly "no hunt stored".
    func testHuntSortExcludesUnhunted() {
        let entries = ["live": hunting(target: 100),
                       "plain": WantEntry(priority: .high, targetUsd: 100)]
        let sorted = WishlistGrid.huntSorted(
            cards: [card("live"), card("plain")], entries: entries,
            prices: ["live": 50, "plain": 10])
        XCTAssertEqual(sorted.map(\.id), ["live"])
    }

    /// Ties break on how long you've been hunting, then card id — never on undefined ordering.
    func testHuntSortTieBreaksOnHowLongYouHaveBeenHuntingThenId() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let entries = ["b": hunting(target: 100, addedAt: new),
                       "a": hunting(target: 100, addedAt: new),
                       "long": hunting(target: 100, addedAt: old)]
        let sorted = WishlistGrid.huntSorted(cards: [card("b"), card("a"), card("long")],
                                             entries: entries,
                                             prices: ["b": 50, "a": 50, "long": 50])
        XCTAssertEqual(sorted.map(\.id), ["long", "a", "b"])
    }

    /// An unpriced card can't be ranked against a budget, so it sorts last rather than
    /// pretending to be a bargain at 0.
    func testHuntSortPutsUnpricedLast() {
        let entries = ["priced": hunting(target: 100),
                       "unpriced": hunting(target: 100)]
        let sorted = WishlistGrid.huntSorted(cards: [card("unpriced"), card("priced")],
                                             entries: entries, prices: ["priced": 95])
        XCTAssertEqual(sorted.map(\.id), ["priced", "unpriced"])
    }

    /// The distinguishing case: A is dearer in absolute terms but closer to its budget.
    /// Ratio ordering gives [A, B]; cheapest-first would give [B, A]. Without differing
    /// targets, every other test in this file passes even with the division removed.
    func testHuntSortIsProximityToBudgetNotCheapest() {
        let entries = ["a": hunting(target: 100),   // 90/100 = 0.90
                       "b": hunting(target: 10)]    // 20/10  = 2.00
        let sorted = WishlistGrid.huntSorted(cards: [card("b"), card("a")],
                                             entries: entries,
                                             prices: ["a": 90, "b": 20])
        XCTAssertEqual(sorted.map(\.id), ["a", "b"])
    }

    /// A zero (or negative) target can't be ranked against a budget any more than a missing
    /// one can — `WishlistEditSheet` treats "0" the same as "no target" for the same reason.
    func testHuntSortExcludesZeroAndNilTargets() {
        let entries = ["zero": hunting(target: 0),
                       "ok":   hunting(target: 50)]
        let sorted = WishlistGrid.huntSorted(cards: [card("zero"), card("ok")], entries: entries,
                                             prices: ["zero": 10, "ok": 25])
        XCTAssertEqual(sorted.map(\.id), ["ok"])
    }
}
