import XCTest
@testable import TheTin

final class CatalogSearchTests: XCTestCase {
    private var store: CatalogStore!

    override func setUpWithError() throws {
        store = try CatalogStore(path: try FixtureCatalog.copyToTemp())
    }

    override func tearDownWithError() throws { try store?.close() }

    func testNamePrefixSearch() throws {
        let hits = try store.search(SearchQuery.parse("ray"))
        XCTAssertEqual(hits.map(\.id), ["swsh7-215"])
    }

    func testMultiTokenNarrows() throws {
        XCTAssertEqual(try store.search(SearchQuery.parse("umbreon v")).map(\.id), ["swsh7-94"])
        XCTAssertEqual(try store.search(SearchQuery.parse("umbreon vmax")).count, 0)
    }

    func testBodyPhraseSearch() throws {
        let hits = try store.search(SearchQuery.parse(#""draw 3 cards""#))
        XCTAssertEqual(hits.map(\.id), ["swsh7-215"])
    }

    func testHPOnlyFilter() throws {
        let hits = try store.search(SearchQuery.parse("hp:100-250"))
        // swsh7-94 (Umbreon V, hp 200) and swsh7-TG20 (Charizard V, hp 220) both fall in range.
        XCTAssertEqual(Set(hits.map(\.id)), ["swsh7-94", "swsh7-TG20"])
    }

    func testNamePlusHP() throws {
        XCTAssertEqual(try store.search(SearchQuery.parse("pikachu hp:60")).map(\.id), ["sv1-25"])
        XCTAssertEqual(try store.search(SearchQuery.parse("pikachu hp:300")).count, 0)
    }

    func testQuoteInjectionIsSafe() throws {
        // must not throw an FTS5 syntax error
        XCTAssertNoThrow(try store.search(SearchQuery.parse(#"ray" OR "x"#)))
    }

    func testEmptyQueryReturnsNothing() throws {
        XCTAssertEqual(try store.search(SearchQuery.parse("")).count, 0)
    }

    func testUnquotedMoveNameMatchesBody() throws {
        // FixtureCatalog.attackNamePhrase ("Draconic Zenith") is swsh7-215's attack name, indexed
        // in card_text.body — should be findable with no quotes, same as a name search.
        XCTAssertEqual(try store.search(SearchQuery.parse("draconic")).map(\.id), [FixtureCatalog.attackNameCardId])
    }

    func testNumberSlashFilter() throws {
        XCTAssertEqual(try store.search(SearchQuery.parse("\(FixtureCatalog.knownNumber)/\(FixtureCatalog.knownTotal)"))
            .map(\.id), [FixtureCatalog.knownCardId])
    }

    func testNumberFilterMatchesPrintedTotalOrTotal() throws {
        // swsh7's printed_total (203) differs from total (237, per FixtureCatalog); either denominator resolves it.
        XCTAssertEqual(try store.search(SearchQuery.parse("215/\(FixtureCatalog.printedTotalValue)")).map(\.id), ["swsh7-215"])
        XCTAssertEqual(try store.search(SearchQuery.parse("215/237")).map(\.id), ["swsh7-215"])
    }

    func testNumberHashFilterNoDenominator() throws {
        XCTAssertEqual(try store.search(SearchQuery.parse("#\(FixtureCatalog.knownNumber)")).map(\.id),
                       [FixtureCatalog.knownCardId])
    }

    func testNumberPlusNameNarrows() throws {
        XCTAssertEqual(try store.search(SearchQuery.parse("pikachu 25/\(FixtureCatalog.knownTotal)")).map(\.id),
                       [FixtureCatalog.knownCardId])
        XCTAssertEqual(try store.search(SearchQuery.parse("umbreon 25/\(FixtureCatalog.knownTotal)")).count, 0)
    }
}
