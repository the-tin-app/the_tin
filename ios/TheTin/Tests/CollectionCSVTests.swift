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
        // for_trade is blank, not "false": an entry that was never marked exports as it always did.
        // …and sold_at/sold_for/acquired_via blank for a card you still own with no recorded source.
        XCTAssertEqual(out[1],
            "swsh7-215,Rayquaza VMAX,swsh7,Evolving Skies,215,Rare Rainbow,2,holo,NM,psa10," +
            "300.00,1970-01-02T00:00:00Z,\"trade, local show\",1970-01-01T00:00:00Z,Binder,1010.00,2026-07-13,,,,,,,")
    }

    /// An export is the whole file, so a copy that has left has to appear in it — with what it
    /// went for. Dropping sold rows would look exactly like a successful backup.
    func testExportCarriesSoldCopies() {
        let entry = CollectionEntry(id: "e1", cardId: "swsh7-215", groupId: "g1", qty: 1,
                                    condition: "NM", grade: nil, pricePaid: 300, acquiredAt: nil,
                                    acquiredFrom: nil, addedAt: Date(timeIntervalSince1970: 0),
                                    variant: "holo",
                                    soldAt: Date(timeIntervalSince1970: 86_400), soldFor: 420)
        let group = CardGroup(id: "g1", name: "Binder", sortOrder: 0, createdAt: Date())
        let data = CollectionCSV.export(entries: [entry], groups: [group],
                                        cards: [card.id: card], sets: [set.id: set],
                                        prices: [card.id: price])
        XCTAssertTrue(lines(data)[1].hasSuffix(",1970-01-02T00:00:00Z,420.00,,,,"), "got \(lines(data)[1])")
    }

    /// The trade flag has to survive "your data is yours": export then re-import must not quietly
    /// drop the list you built.
    func testExportMarksCardsAvailableToTrade() {
        let entry = CollectionEntry(id: "e1", cardId: "swsh7-215", groupId: "g1", qty: 1,
                                    condition: "NM", grade: nil, pricePaid: nil, acquiredAt: nil,
                                    acquiredFrom: nil, addedAt: Date(timeIntervalSince1970: 0),
                                    variant: "holo", forTrade: true)
        let group = CardGroup(id: "g1", name: "Binder", sortOrder: 0, createdAt: Date())
        let data = CollectionCSV.export(entries: [entry], groups: [group],
                                        cards: [card.id: card], sets: [set.id: set],
                                        prices: [card.id: price])
        // for_trade is followed by the (empty) sold_at/sold_for/acquired_via columns.
        XCTAssertTrue(lines(data)[1].hasSuffix(",true,,,,,,"), "got \(lines(data)[1])")
    }

    func testExportUnknownCardAndUngroupedGoesBlankNotCrash() {
        let entry = CollectionEntry(id: "e2", cardId: "gone-1", groupId: "", qty: 1, condition: nil,
                                    grade: nil, pricePaid: nil, acquiredAt: nil, acquiredFrom: nil,
                                    addedAt: Date(timeIntervalSince1970: 0))
        let data = CollectionCSV.export(entries: [entry], groups: [], cards: [:], sets: [:], prices: [:])
        XCTAssertEqual(lines(data)[1], "gone-1,,,,,,1,,,,,,,1970-01-01T00:00:00Z,,,,,,,,,,")
    }

    func testWishlistExport() {
        let data = CollectionCSV.exportWishlist(cards: [card], sets: [set.id: set],
                                                prices: [card.id: price])
        let out = lines(data)
        XCTAssertEqual(out[0], "card_id,name,set_id,set_name,number,market_usd,as_of,priority,target_usd,notes")
        XCTAssertEqual(out[1], "swsh7-215,Rayquaza VMAX,swsh7,Evolving Skies,215,92.50,2026-07-13,,,")
    }

    /// The `.csv` extension is part of the filename, not something `fileExporter` adds. It
    /// doesn't — a real export arrived as a bare name, which iOS types as `public.data`, so
    /// nothing would open it and our own importer greyed it out (2026-07-27).
    func testFilenameStampsDateAndCarriesTheExtension() {
        XCTAssertEqual(CollectionCSV.filename("the-tin-collection",
                                              on: Date(timeIntervalSince1970: 0)),
                       "the-tin-collection-1970-01-01.csv")
    }

    /// Both axes reach the file, and they read the same way the app prints them.
    func testExportWritesCentering() {
        var entry = CollectionEntry(id: "e1", cardId: "swsh7-215", groupId: "", qty: 1,
                                    condition: nil, grade: nil, pricePaid: nil, acquiredAt: nil,
                                    acquiredFrom: nil, addedAt: Date(timeIntervalSince1970: 0))
        entry.centering = Centering(outerLeft: 10, innerLeft: 65, outerRight: 5, innerRight: 50,
                                    outerTop: 8, innerTop: 61, outerBottom: 3, innerBottom: 50)
        let data = CollectionCSV.export(entries: [entry], groups: [],
                                        cards: [card.id: card], sets: [set.id: set], prices: [:])
        let row = lines(data)[1]
        // left 55, right 45 → 55/45; top 53, bottom 47 → 53/47. Same rounding as the screen.
        XCTAssertTrue(row.hasSuffix(",55/45,53/47"), "got \(row)")
        XCTAssertEqual(entry.centering?.summary, "55/45 L-R · 53/47 T-B",
                       "the file and the screen must not disagree by a point")
    }

    /// Every row has to be the header's width. A sealed box has no borders to centre, so it
    /// exports blanks — but blanks that are PRESENT, or the file is malformed for everyone.
    func testSealedRowsAreTheSameWidthAsCardRows() {
        var entry = CollectionEntry(id: "e1", cardId: "swsh7-215", groupId: "", qty: 1,
                                    condition: nil, grade: nil, pricePaid: nil, acquiredAt: nil,
                                    acquiredFrom: nil, addedAt: Date(timeIntervalSince1970: 0))
        entry.centering = Centering(left: 40, right: 20, top: 30, bottom: 60)
        let sealedEntry = SealedEntry(id: "s1", productId: 517_898, qty: 1,
                                      addedAt: Date(timeIntervalSince1970: 0))
        let data = CollectionCSV.export(entries: [entry], groups: [],
                                        cards: [card.id: card], sets: [set.id: set], prices: [:],
                                        sealed: [sealedEntry], sealedProducts: [517_898: box])
        for row in lines(data) {
            XCTAssertEqual(row.components(separatedBy: ",").count, CollectionCSV.header.count,
                           "row is not the header's width: \(row)")
        }
    }

    /// New columns are appended LAST — third-party importers read this header positionally, so an
    /// inserted column silently shifts every field after it.
    func testNewColumnsAreAppendedNotInserted() {
        XCTAssertEqual(Array(CollectionCSV.header.suffix(2)), ["centering_lr", "centering_tb"])
    }

    // MARK: Sealed products

    private var box: SealedProduct {
        SealedProduct(tcgplayerId: 517_898, name: "Evolving Skies Booster Box", setId: "swsh7",
                      productType: "Booster Box", marketUsd: 500, lowUsd: 450, asOf: "2026-07-13")
    }

    /// Sealed rows carry an EMPTY card number — precisely the shape the importer already reads as
    /// "sealed" — plus the product id, which is what makes our own round trip exact rather than a
    /// name-matching guess.
    func testExportWritesSealedRowsWithNoCardNumber() throws {
        let entry = SealedEntry(id: "s1", productId: 517_898, qty: 2, pricePaid: 800,
                                acquiredAt: Date(timeIntervalSince1970: 86_400),
                                acquiredFrom: "Card shop",
                                acquiredVia: AcquiredVia.bought.rawValue,
                                addedAt: Date(timeIntervalSince1970: 0))
        let out = lines(CollectionCSV.export(entries: [], groups: [], cards: [:],
                                             sets: [set.id: set], prices: [:],
                                             sealed: [entry], sealedProducts: [517_898: box]))
        let f = try XCTUnwrap(out.last).components(separatedBy: ",")

        XCTAssertEqual(f.count, CollectionCSV.header.count)
        XCTAssertEqual(f[0], "")                              // card_id — a box has none
        XCTAssertEqual(f[1], "Evolving Skies Booster Box")
        XCTAssertEqual(f[4], "")                              // number — THE sealed signal
        XCTAssertEqual(f[6], "2")                             // qty
        XCTAssertEqual(f[15], "1000.00")                      // current_value: 500 × 2
        XCTAssertEqual(f[20], "bought")
        XCTAssertEqual(f[f.count - 3], "517898")              // tcgplayer_id, now third from last
    }

    /// A box the catalog no longer prices still exports: quantity and cost basis are the user's
    /// own data, and dropping the row to avoid a blank name column would destroy them.
    func testExportKeepsSealedRowsForUnknownProducts() throws {
        let entry = SealedEntry(id: "s1", productId: 999, qty: 1, pricePaid: 120,
                                addedAt: Date(timeIntervalSince1970: 0))
        let out = lines(CollectionCSV.export(entries: [], groups: [], cards: [:], sets: [:],
                                             prices: [:], sealed: [entry], sealedProducts: [:]))
        let f = try XCTUnwrap(out.last).components(separatedBy: ",")

        XCTAssertEqual(f.count, CollectionCSV.header.count)
        XCTAssertEqual(f[1], "")            // no name to write
        XCTAssertEqual(f[10], "120.00")     // price_paid survives
        XCTAssertEqual(f[15], "")           // no price ⇒ blank, never $0
        XCTAssertEqual(f[f.count - 3], "999")
    }

    func testExportWritesTheAcquisitionSource() throws {
        let entry = CollectionEntry(id: "e1", cardId: "swsh7-215", groupId: "", qty: 1,
                                    condition: "NM", grade: nil, pricePaid: nil, acquiredAt: nil,
                                    acquiredFrom: nil, addedAt: Date(), variant: "regular",
                                    acquiredVia: AcquiredVia.pulled.rawValue)
        let out = lines(CollectionCSV.export(entries: [entry], groups: [],
                                             cards: ["swsh7-215": card],
                                             sets: ["swsh7": set],
                                             prices: ["swsh7-215": price]))
        let row = try XCTUnwrap(out.last)
        XCTAssertTrue(row.hasSuffix(",pulled,,,"),
                      "source should be followed only by blank tcgplayer_id + centring: \(row)")
    }

    /// An unrecorded source writes an empty field, not the word "nil" or a default.
    func testExportLeavesUnrecordedSourceBlank() throws {
        let entry = CollectionEntry(id: "e1", cardId: "swsh7-215", groupId: "", qty: 1,
                                    condition: "NM", grade: nil, pricePaid: nil, acquiredAt: nil,
                                    acquiredFrom: nil, addedAt: Date(), variant: "regular",
                                    acquiredVia: nil)
        let out = lines(CollectionCSV.export(entries: [entry], groups: [],
                                             cards: ["swsh7-215": card],
                                             sets: ["swsh7": set],
                                             prices: ["swsh7-215": price]))
        let row = try XCTUnwrap(out.last)
        // A bare trailing "," alone would still pass if the acquired_via column were deleted
        // entirely, since sold_at/sold_for are already blank. Assert the field count instead, so
        // the test fails if the column disappears rather than just staying empty.
        XCTAssertEqual(row.components(separatedBy: ",").count, CollectionCSV.header.count,
                       "row should have one field per header column, including a blank acquired_via: \(row)")
        XCTAssertTrue(row.hasSuffix(",,,"), "acquired_via should be blank: \(row)")
    }
}
