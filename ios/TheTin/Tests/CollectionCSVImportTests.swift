import XCTest
@testable import TheTin

final class CSVRecordIteratorTests: XCTestCase {
    private func records(_ text: String) -> [[String]] {
        var it = CSVRecordIterator(text)
        var out: [[String]] = []
        while let r = it.next() { out.append(r) }
        return out
    }

    func testPlainRecordsLFAndCRLF() {
        XCTAssertEqual(records("a,b\r\nc,d\ne,f"), [["a", "b"], ["c", "d"], ["e", "f"]])
    }

    func testQuotedCommaAndEscapedQuotes() {
        XCTAssertEqual(records("\"a,b\",c\n\"say \"\"hi\"\"\",d"),
                       [["a,b", "c"], ["say \"hi\"", "d"]])
    }

    func testQuotedNewlineStaysInsideField() {
        XCTAssertEqual(records("\"line1\nline2\",x\n"), [["line1\nline2", "x"]])
    }

    func testBOMStripped() {
        XCTAssertEqual(records("\u{FEFF}a,b\n"), [["a", "b"]])
    }

    func testBlankLinesSkippedAndEmptyFieldsKept() {
        XCTAssertEqual(records("a,,c\n\n\nd,e,\n"), [["a", "", "c"], ["d", "e", ""]])
    }

    func testTrailingRecordWithoutNewline() {
        XCTAssertEqual(records("a,b"), [["a", "b"]])
    }

    func testDanglingQuoteSwallowsRemainderAsOneBadRecord() {
        // Malformed input: an unterminated quote makes the rest one field — one bad record
        // (reported by the importer's field-count check), not corruption of every later row.
        XCTAssertEqual(records("a,b\nc,\"oops\nd,e"), [["a", "b"], ["c", "oops\nd,e"]])
    }

    func testBareCRSeparatedRecords() {
        // Lone CR (not followed by LF) should be treated as a record separator
        XCTAssertEqual(records("a,b\rc,d\r"), [["a", "b"], ["c", "d"]])
    }

    func testBareCRFollowedByQuotedField() {
        // Lone CR immediately followed by a quoted field should preserve quote detection
        XCTAssertEqual(records("a,b\r\"c,c\",d"), [["a", "b"], ["c,c", "d"]])
    }
}

final class CatalogStoreTcgplayerIdTests: XCTestCase {
    func testCardByTcgplayerId() throws {
        let store = try FixtureCatalog.make()
        XCTAssertEqual(try store.card(tcgplayerId: 4)?.id, "sv1-25")   // fixture: Pikachu
        XCTAssertNil(try store.card(tcgplayerId: 424_242))
    }
}

final class CardMatcherTests: XCTestCase {
    private var matcher: CardMatcher!

    override func setUpWithError() throws {
        matcher = CardMatcher(store: try FixtureCatalog.make())
    }

    private func matchedId(_ row: ImportedRow) -> String? {
        if case .matched(let card) = matcher.match(row) { return card.id }
        return nil
    }

    private func reason(_ row: ImportedRow) -> String {
        if case .unmatched(let r) = matcher.match(row) { return r }
        return ""
    }

    func testCardIdAuthoritativeAndUnknownRejected() {
        XCTAssertEqual(matchedId(ImportedRow(cardId: "sv1-25")), "sv1-25")
        XCTAssertTrue(reason(ImportedRow(cardId: "nope-1")).contains("unknown card_id"))
    }

    func testTcgplayerIdPathThenSetNumberFallback() {
        var row = ImportedRow()
        row.tcgplayerId = 4                      // fixture: sv1-25 Pikachu
        XCTAssertEqual(matchedId(row), "sv1-25")

        var fallback = ImportedRow()
        fallback.tcgplayerId = 99_999            // unknown id → set+number rescue
        fallback.setName = "Evolving Skies"
        fallback.number = "215/203"
        XCTAssertEqual(matchedId(fallback), "swsh7-215")
    }

    func testSetNameNormalizationAndZeroPaddedPrintedNumber() {
        var row = ImportedRow()
        row.setName = "scarlet & violet"         // case + punctuation insensitive
        row.number = "025/198"                   // zero-padded printed form
        XCTAssertEqual(matchedId(row), "sv1-25")
    }

    func testPromoNumberKeepsLetters() {
        var row = ImportedRow()
        row.setName = "Evolving Skies"
        row.number = "TG20"
        XCTAssertEqual(matchedId(row), "swsh7-TG20")
    }

    func testNameFallbackWhenNumberMissing() {
        var row = ImportedRow()
        row.setName = "Evolving Skies"
        row.cardName = "Umbreon V"
        XCTAssertEqual(matchedId(row), "swsh7-94")
    }

    func testSetCodeTriedAgainstOurSetIds() {
        var row = ImportedRow()
        row.setCode = "SWSH7"                    // matches our set id, case-insensitively
        row.number = "94"
        XCTAssertEqual(matchedId(row), "swsh7-94")
    }

    func testUnknownSetAndNoMatchGiveReadableReasons() {
        var row = ImportedRow()
        row.setName = "Base Set"
        row.number = "4/102"
        XCTAssertTrue(reason(row).contains("set not found"))

        var miss = ImportedRow()
        miss.setName = "Evolving Skies"
        miss.number = "999"
        miss.cardName = "Missingno"
        XCTAssertTrue(reason(miss).contains("no match"))
    }
}

final class CSVImportCoreTests: XCTestCase {
    private var matcher: CardMatcher!

    override func setUpWithError() throws {
        matcher = CardMatcher(store: try FixtureCatalog.make())
    }

    func testEmptyFileThrows() {
        XCTAssertThrowsError(try CollectionCSVImport.importCSV("", matcher: matcher)) {
            XCTAssertEqual($0 as? CollectionCSVImport.ImportError, .emptyFile)
        }
    }

    func testUnrecognizedHeaderThrows() {
        XCTAssertThrowsError(try CollectionCSVImport.importCSV("foo,bar\n1,2\n", matcher: matcher)) {
            XCTAssertEqual($0 as? CollectionCSVImport.ImportError, .unrecognizedFormat)
        }
    }

    func testWishlistExportIsNotImportableAsOwnedCards() {
        // Wishlist header has card_id but no qty — must NOT be swallowed by the Tin format.
        let csv = CollectionCSV.wishlistHeader.joined(separator: ",") + "\nsv1-25,Pikachu,sv1,S,25,1.00,2026-07-13\n"
        XCTAssertThrowsError(try CollectionCSVImport.importCSV(csv, matcher: matcher)) {
            XCTAssertEqual($0 as? CollectionCSVImport.ImportError, .unrecognizedFormat)
        }
    }

    func testRowCapThrowsClearError() {
        // Rows are "," (2 empty fields) — skipped cheaply without touching the catalog.
        let csv = "card_id,qty\n" + String(repeating: ",\n", count: CollectionCSVImport.rowCap + 1)
        XCTAssertThrowsError(try CollectionCSVImport.importCSV(csv, matcher: matcher)) {
            XCTAssertEqual($0 as? CollectionCSVImport.ImportError, .tooManyRows)
        }
    }

    func testTinRoundTripExportThenImport() throws {
        let original = CollectionEntry(id: "e1", cardId: "swsh7-215", groupId: "g1", qty: 2,
                                       condition: "LP", grade: "psa10", pricePaid: 1234.5,
                                       acquiredAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       acquiredFrom: "trade, local show",
                                       addedAt: Date(timeIntervalSince1970: 1_750_000_000),
                                       variant: "reverseHolo")
        let store = try FixtureCatalog.make()
        let cards = Dictionary(uniqueKeysWithValues: try store.cards(ids: ["swsh7-215"]).map { ($0.id, $0) })
        let sets = Dictionary(uniqueKeysWithValues: try store.sets().map { ($0.id, $0) })
        let group = CardGroup(id: "g1", name: "Binder", sortOrder: 0, createdAt: Date())
        let csv = CollectionCSV.export(entries: [original], groups: [group],
                                       cards: cards, sets: sets, prices: [:])
        // Feed the exported bytes straight back (BOM included — the iterator strips it).
        let result = try CollectionCSVImport.importCSV(String(decoding: csv, as: UTF8.self),
                                                       matcher: matcher)
        XCTAssertEqual(result.formatName, "The Tin")
        XCTAssertFalse(result.experimental)
        XCTAssertTrue(result.skipped.isEmpty)
        let e = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(e.cardId, original.cardId)
        XCTAssertEqual(e.qty, original.qty)
        XCTAssertEqual(e.condition, original.condition)
        XCTAssertEqual(e.grade, original.grade)
        XCTAssertEqual(e.variant, original.variant)
        XCTAssertEqual(e.pricePaid, original.pricePaid)
        XCTAssertEqual(e.acquiredAt, original.acquiredAt)
        XCTAssertEqual(e.acquiredFrom, original.acquiredFrom)
        XCTAssertEqual(e.addedAt, original.addedAt)
        XCTAssertEqual(e.groupId, "")   // caller re-homes into the "Imported …" divider
    }

    func testUnknownCardIdAndMalformedRowSkippedWithReasons() throws {
        let csv = "card_id,qty\nsv1-25,1\nbogus-9,1\nsv1-1\n"
        let result = try CollectionCSVImport.importCSV(csv, matcher: matcher)
        XCTAssertEqual(result.entries.map(\.cardId), ["sv1-25"])
        XCTAssertEqual(result.skipped.count, 2)
        XCTAssertTrue(result.skipped[0].reason.contains("unknown card_id"))
        XCTAssertTrue(result.skipped[1].reason.contains("malformed"))   // 1 of 2 columns
        XCTAssertEqual(result.summary, "1 cards imported, 2 rows skipped.")
    }

    func testSkippedRowsCSVHasOriginalRowPlusReason() throws {
        let result = try CollectionCSVImport.importCSV("card_id,qty\nbogus-9,1\n", matcher: matcher)
        let out = String(decoding: CollectionCSVImport.skippedRowsCSV(result).dropFirst(3),
                         as: UTF8.self).components(separatedBy: "\r\n")
        XCTAssertEqual(out[0], "card_id,qty,skip_reason")
        XCTAssertTrue(out[1].hasPrefix("bogus-9,1,"))
    }
}

final class CollectrImportTests: XCTestCase {
    private var matcher: CardMatcher!

    override func setUpWithError() throws {
        matcher = CardMatcher(store: try FixtureCatalog.make())
    }

    /// Verbatim 16-column Collectr header, WITH the dated Market Price quirk baked in.
    private let header = "Portfolio Name,Category,Set,Product Name,Card Number,Rarity,Variance,"
        + "Grade,Card Condition,Average Cost Paid,Quantity,Market Price (2026-01-15),"
        + "Price Override,Watchlist,Date Added,Notes"

    private func run(_ rows: [String], header: String? = nil) throws -> CollectionCSVImport.Result {
        let text = ([header ?? self.header] + rows).joined(separator: "\n") + "\n"
        return try CollectionCSVImport.importCSV(text, matcher: matcher)
    }

    func testDetectionAndFullRowWithMoneyAndDateQuirks() throws {
        let result = try run([#"Main,Pokemon,Evolving Skies,Rayquaza VMAX,215/203,Secret Rare,Holofoil,Ungraded,Near Mint,"$1,234.56",2,$505.00,,No,2026-01-10,from grandma"#])
        XCTAssertEqual(result.formatName, "Collectr")
        XCTAssertFalse(result.experimental)
        let e = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(e.cardId, "swsh7-215")            // set name + printed number, no IDs
        XCTAssertEqual(e.qty, 2)
        XCTAssertEqual(e.variant, CardVariant.holo.rawValue)
        XCTAssertEqual(e.condition, "NM")
        XCTAssertNil(e.grade)                            // Ungraded
        XCTAssertEqual(e.pricePaid, 1234.56)             // "$1,234.56"
        XCTAssertEqual(e.acquiredFrom, "from grandma")   // Notes column
        // Date Added "2026-01-10" parsed as a UTC day.
        var comps = DateComponents(year: 2026, month: 1, day: 10)
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(identifier: "UTC")
        XCTAssertEqual(e.addedAt, comps.date)
    }

    func testPSAGradeMapsAndCGCBecomesNote() throws {
        // Second row's Category uses the accented "Pokémon" — must still pass the filter.
        let result = try run([
            "Main,Pokemon,Evolving Skies,Rayquaza VMAX,215/203,,Holofoil,PSA 10,Near Mint,$400,1,$505,,No,2026-01-10,",
            "Main,Pokémon,Scarlet & Violet,Pikachu,25/198,,Normal,CGC 9.5,Near Mint,$50,1,$60,,No,2026-01-10,",
        ])
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].grade, "psa10")
        XCTAssertNil(result.entries[1].grade)
        XCTAssertEqual(result.entries[1].acquiredFrom, "Grade: CGC 9.5")   // preserved, not dropped
        XCTAssertEqual(result.entries[1].variant, CardVariant.regular.rawValue)
    }

    func testSealedEmptyNumberSkippedAndCountedSeparately() throws {
        let result = try run(["Main,Pokemon,Evolving Skies,Booster Box,,,Normal,Ungraded,Near Mint,$120,1,$150,,No,2026-01-10,"])
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.skipped[0].reason.hasPrefix("sealed"))
        XCTAssertEqual(result.summary, "0 cards imported, 1 rows skipped. 1 sealed products (not supported).")
    }

    func testNonPokemonCategorySkipped() throws {
        let result = try run(["Main,Magic,Alpha,Black Lotus,1/100,,Normal,Ungraded,Near Mint,$1,1,$2,,No,2026-01-10,"])
        XCTAssertTrue(result.skipped[0].reason.contains("non-Pokémon"))
    }

    func testJPMarkerSkippedWhenNoLanguageColumn() throws {
        let result = try run(["Main,Pokemon,Scarlet & Violet (JP),Pikachu (JP),25/102,,Normal,Ungraded,Near Mint,$10,1,$20,,No,2026-01-10,"])
        XCTAssertTrue(result.skipped[0].reason.contains("Japanese"))
    }

    func testOptionalLanguageColumnReadByNameAndMasterBallVariance() throws {
        // Newer exports append Language — columns MUST be read by name, not position.
        let result = try run([
            "Main,Pokemon,Scarlet & Violet,Pikachu,25/198,,Reverse Holofoil,Ungraded,Lightly Played,$5,1,$6,,No,2026-01-10,,Japanese",
            "Main,Pokemon,Scarlet & Violet,Pikachu,25/198,,Master Ball Reverse Holo,Ungraded,Lightly Played,$5,3,$6,,No,2026-01-10,,English",
        ], header: header + ",Language")
        XCTAssertTrue(result.skipped[0].reason.contains("non-English"))
        let e = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(e.qty, 3)
        XCTAssertEqual(e.variant, CardVariant.reverseHolo.rawValue)   // Master Ball → reverse holo
        XCTAssertEqual(e.condition, "LP")
    }
}

final class TCGplayerImportTests: XCTestCase {
    private var matcher: CardMatcher!

    override func setUpWithError() throws {
        matcher = CardMatcher(store: try FixtureCatalog.make())
    }

    /// Verbatim header + first data row of the public sample
    /// (github.com/pmerrild/ptcg_collection fixtures/TCGplayerCardList.csv).
    private let header = "Quantity,Name,Simple Name,Set,Card Number,Set Code,Printing,Condition,"
        + "Language,Rarity,Product ID,SKU,Price,Price Each"
    private let publicRow = "5,Water Energy,Water Energy,Base Set,102/102,BS,Normal,Near Mint,"
        + "English,Common,42350,460401,$1.65,$0.33"

    private func run(_ rows: [String]) throws -> CollectionCSVImport.Result {
        try CollectionCSVImport.importCSV(([header] + rows).joined(separator: "\n") + "\n",
                                          matcher: matcher)
    }

    func testVerbatimPublicSampleRowParses() throws {
        // The verbatim public row: Base Set / product 42350 aren't in the test catalog, so it
        // must land in skipped with a set-not-found reason — proving the row itself parses.
        let result = try run([publicRow])
        XCTAssertEqual(result.formatName, "TCGplayer Card List")
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.skipped[0].reason.contains("set not found"))
    }

    func testProductIdMatchesTcgplayerIdDirectly() throws {
        // Same shape as the public row, Product ID pointed at fixture card sv1-25 (id 4).
        let result = try run(["3,Pikachu,Pikachu,Scarlet & Violet,025/198,SVI,Reverse Holofoil,Lightly Played,English,Common,4,460401,$1.65,$0.33"])
        let e = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(e.cardId, "sv1-25")
        XCTAssertEqual(e.qty, 3)
        XCTAssertEqual(e.variant, CardVariant.reverseHolo.rawValue)   // full-word Printing
        XCTAssertEqual(e.condition, "LP")                             // full-word Condition
        XCTAssertNil(e.pricePaid)   // Price/Price Each are market prices, never cost paid
    }

    func testMissingProductIdFallsBackToSetPlusZeroPaddedNumber() throws {
        let result = try run(["1,Rayquaza VMAX,Rayquaza VMAX,Evolving Skies,215/203,EVS,Holofoil,Near Mint,English,Secret Rare,,999,$505.00,$505.00"])
        let e = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(e.cardId, "swsh7-215")
        XCTAssertEqual(e.variant, CardVariant.holo.rawValue)
        XCTAssertEqual(e.condition, "NM")
    }

    func testNonEnglishRowSkipped() throws {
        let result = try run(["1,Pikachu,Pikachu,Scarlet & Violet,025/198,SVI,Normal,Near Mint,Japanese,Common,4,1,$1,$1"])
        XCTAssertTrue(result.skipped[0].reason.contains("non-English"))
    }
}

final class TCGCollectorImportTests: XCTestCase {
    private var matcher: CardMatcher!

    override func setUpWithError() throws {
        matcher = CardMatcher(store: try FixtureCatalog.make())
    }

    func testHeaderSniffingMapsColumnsAndFlagsExperimental() throws {
        // Synthetic header at the evidenced positions (name@1, number@2, expansion@4,
        // rarity@5, variant@6, quantity@9) — exact names unknown, keywords must carry it.
        let header = "Id,Name,Number,Foo,Expansion,Rarity,Variant,Bar,Baz,Quantity"
        let row = "7,Umbreon V,94,x,Evolving Skies,Rare,Reverse Holo,y,z,2"
        let result = try CollectionCSVImport.importCSV(header + "\n" + row + "\n", matcher: matcher)
        XCTAssertEqual(result.formatName, "TCG Collector")
        XCTAssertTrue(result.experimental)
        let e = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(e.cardId, "swsh7-94")
        XCTAssertEqual(e.qty, 2)
        XCTAssertEqual(e.variant, CardVariant.reverseHolo.rawValue)
    }

    func testCardNameColumnBeatsExpansionNameColumn() throws {
        // "Card Name" + "Expansion Name" both contain "name" — exact/most-specific must win.
        let header = "Card Name,Card Number,Expansion Name,Quantity"
        let row = "Pikachu,25,Scarlet & Violet,1"
        let result = try CollectionCSVImport.importCSV(header + "\n" + row + "\n", matcher: matcher)
        XCTAssertEqual(result.formatName, "TCG Collector")
        XCTAssertEqual(result.entries.first?.cardId, "sv1-25")
    }

    func testExactFormatsNeverFallThroughToSniffer() throws {
        // A Tin header also contains name/number/set/qty keywords — order must keep it Tin.
        let tin = try CollectionCSVImport.importCSV("card_id,name,number,set_name,qty\nsv1-25,,,,1\n",
                                                    matcher: matcher)
        XCTAssertEqual(tin.formatName, "The Tin")
    }
}
