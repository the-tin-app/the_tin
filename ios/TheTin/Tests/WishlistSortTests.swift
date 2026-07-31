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
