import XCTest
@testable import TheTin

final class CardGridSortTests: XCTestCase {
    private static func card(_ id: String, _ num: String, _ name: String) -> CardRecord {
        CardRecord(id: id, setId: "s", number: num, name: name, hp: nil, types: [], rarity: nil,
                   artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }
    private let cards = [card("s-2","2","Bulbasaur"), card("s-1","1","Pikachu"), card("s-3","3","Abra")]
    private let prices = ["s-1": 10.0, "s-2": 1.0, "s-3": 5.0]

    func testNumber() {
        let out = CardGridSort.apply(cards: cards, prices: prices, owned: [], wanted: [], setDates: [:], sort: .number, filter: .all)
        XCTAssertEqual(out.map(\.number), ["1","2","3"])
    }
    func testAlphabetical() {
        let out = CardGridSort.apply(cards: cards, prices: prices, owned: [], wanted: [], setDates: [:], sort: .alphabetical, filter: .all)
        XCTAssertEqual(out.map(\.name), ["Abra","Bulbasaur","Pikachu"])
    }
    func testCheapest() {
        let out = CardGridSort.apply(cards: cards, prices: prices, owned: [], wanted: [], setDates: [:], sort: .cheapest, filter: .all)
        XCTAssertEqual(out.map(\.id), ["s-2","s-3","s-1"])
    }
    func testExpensive() {
        let out = CardGridSort.apply(cards: cards, prices: prices, owned: [], wanted: [], setDates: [:], sort: .expensive, filter: .all)
        XCTAssertEqual(out.map(\.id), ["s-1","s-3","s-2"])
    }
    func testFilterOwned() {
        let out = CardGridSort.apply(cards: cards, prices: prices, owned: ["s-1"], wanted: [], setDates: [:], sort: .number, filter: .owned)
        XCTAssertEqual(out.map(\.id), ["s-1"])
    }
    func testFilterWanted() {
        let out = CardGridSort.apply(cards: cards, prices: prices, owned: [], wanted: ["s-3"], setDates: [:], sort: .number, filter: .wanted)
        XCTAssertEqual(out.map(\.id), ["s-3"])
    }
}
