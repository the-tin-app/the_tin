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

    private func hunting(target: Double, days: Double, from now: Date) -> WantEntry {
        WantEntry(priority: .grail, targetUsd: target, notes: "", addedAt: .distantPast,
                  hunt: Hunt(minCondition: .hp, until: now.addingTimeInterval(days * 86_400)))
    }

    /// Sorted by proximity to budget (market/target ascending), so the top row is the card
    /// most likely to be buyable today — not the cheapest, and not alphabetical.
    func testHuntSortLeadsWithClosestToBudget() {
        let now = Date(timeIntervalSince1970: 800_000_000)
        let entries = ["far": hunting(target: 100, days: 10, from: now),   // 90/100 = 0.90
                       "near": hunting(target: 100, days: 10, from: now)]  // 60/100 = 0.60
        let sorted = WishlistGrid.huntSorted(cards: [card("far"), card("near")],
                                             entries: entries,
                                             prices: ["far": 90, "near": 60], now: now)
        XCTAssertEqual(sorted.map(\.id), ["near", "far"])
    }

    /// Expired hunts are not hunting. They stay wanted — they just leave this scope.
    func testHuntSortExcludesExpiredAndUnhunted() {
        let now = Date(timeIntervalSince1970: 800_000_000)
        let entries = ["live": hunting(target: 100, days: 5, from: now),
                       "dead": hunting(target: 100, days: -5, from: now),
                       "plain": WantEntry(priority: .high, targetUsd: 100)]
        let sorted = WishlistGrid.huntSorted(
            cards: [card("live"), card("dead"), card("plain")], entries: entries,
            prices: ["live": 50, "dead": 10, "plain": 10], now: now)
        XCTAssertEqual(sorted.map(\.id), ["live"])
    }

    /// Ties break on the soonest deadline, then card id — never on undefined ordering.
    func testHuntSortTieBreaksOnDeadlineThenId() {
        let now = Date(timeIntervalSince1970: 800_000_000)
        let entries = ["b": hunting(target: 100, days: 30, from: now),
                       "a": hunting(target: 100, days: 30, from: now),
                       "soon": hunting(target: 100, days: 2, from: now)]
        let sorted = WishlistGrid.huntSorted(cards: [card("b"), card("a"), card("soon")],
                                             entries: entries,
                                             prices: ["b": 50, "a": 50, "soon": 50], now: now)
        XCTAssertEqual(sorted.map(\.id), ["soon", "a", "b"])
    }

    /// An unpriced card can't be ranked against a budget, so it sorts last rather than
    /// pretending to be a bargain at 0.
    func testHuntSortPutsUnpricedLast() {
        let now = Date(timeIntervalSince1970: 800_000_000)
        let entries = ["priced": hunting(target: 100, days: 10, from: now),
                       "unpriced": hunting(target: 100, days: 10, from: now)]
        let sorted = WishlistGrid.huntSorted(cards: [card("unpriced"), card("priced")],
                                             entries: entries, prices: ["priced": 95], now: now)
        XCTAssertEqual(sorted.map(\.id), ["priced", "unpriced"])
    }
}
