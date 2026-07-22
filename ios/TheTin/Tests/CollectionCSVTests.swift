import XCTest
@testable import TheTin

final class CollectionCSVTests: XCTestCase {
    private let card = CardRecord(id: "swsh7-215", setId: "swsh7", number: "215",
                                  name: "Rayquaza VMAX", hp: 320, types: [], rarity: "Rare Rainbow",
                                  artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: 1)
    private let set = SetRecord(id: "swsh7", name: "Evolving Skies", releaseDate: nil, total: 237,
                                era: nil, repCardId: nil)
    private let price = PriceRecord(cardId: "swsh7-215", rawUsd: 92.5, rawEur: nil, psa3: nil,
                                    psa7: nil, psa9: nil, psa10: 505, asOf: "2026-07-13")

    private func lines(_ data: Data) -> [String] {
        // Drop the 3-byte BOM, split on CRLF, drop the trailing empty line.
        String(decoding: data.dropFirst(3), as: UTF8.self)
            .components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    func testFieldQuoting() {
        XCTAssertEqual(CollectionCSV.field("plain"), "plain")
        XCTAssertEqual(CollectionCSV.field("a,b"), "\"a,b\"")
        XCTAssertEqual(CollectionCSV.field("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CollectionCSV.field("line1\nline2"), "\"line1\nline2\"")
    }

    func testDataStartsWithUTF8BOM() {
        XCTAssertEqual([UInt8](CollectionCSV.data([["a"]]).prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    func testExportRowValues() {
        let entry = CollectionEntry(id: "e1", cardId: "swsh7-215", groupId: "g1", qty: 2,
                                    condition: "NM", grade: "psa10", pricePaid: 300,
                                    acquiredAt: Date(timeIntervalSince1970: 86_400),
                                    acquiredFrom: "trade, local show",
                                    addedAt: Date(timeIntervalSince1970: 0), variant: "holo")
        let group = CardGroup(id: "g1", name: "Binder", sortOrder: 0, createdAt: Date())
        let data = CollectionCSV.export(entries: [entry], groups: [group],
                                        cards: [card.id: card], sets: [set.id: set],
                                        prices: [card.id: price])
        let out = lines(data)
        XCTAssertEqual(out[0], CollectionCSV.header.joined(separator: ","))
        // current_value: psa10 505 × qty 2 = 1010.00 (same GroupStats.entryValue the app shows).
        // acquiredFrom contains a comma → quoted.
        XCTAssertEqual(out[1],
            "swsh7-215,Rayquaza VMAX,swsh7,Evolving Skies,215,Rare Rainbow,2,holo,NM,psa10," +
            "300.00,1970-01-02T00:00:00Z,\"trade, local show\",1970-01-01T00:00:00Z,Binder,1010.00,2026-07-13")
    }

    func testExportUnknownCardAndUngroupedGoesBlankNotCrash() {
        let entry = CollectionEntry(id: "e2", cardId: "gone-1", groupId: "", qty: 1, condition: nil,
                                    grade: nil, pricePaid: nil, acquiredAt: nil, acquiredFrom: nil,
                                    addedAt: Date(timeIntervalSince1970: 0))
        let data = CollectionCSV.export(entries: [entry], groups: [], cards: [:], sets: [:], prices: [:])
        XCTAssertEqual(lines(data)[1], "gone-1,,,,,,1,,,,,,,1970-01-01T00:00:00Z,,,")
    }

    func testWishlistExport() {
        let data = CollectionCSV.exportWishlist(cards: [card], sets: [set.id: set],
                                                prices: [card.id: price])
        let out = lines(data)
        XCTAssertEqual(out[0], "card_id,name,set_id,set_name,number,market_usd,as_of,priority,target_usd,notes")
        XCTAssertEqual(out[1], "swsh7-215,Rayquaza VMAX,swsh7,Evolving Skies,215,92.50,2026-07-13,,,")
    }

    func testFilenameStampsDate() {
        XCTAssertEqual(CollectionCSV.filename("the-tin-collection",
                                              on: Date(timeIntervalSince1970: 0)),
                       "the-tin-collection-1970-01-01")
    }
}
