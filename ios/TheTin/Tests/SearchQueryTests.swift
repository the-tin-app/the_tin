import XCTest
@testable import TheTin

final class SearchQueryTests: XCTestCase {
    func testPlainTokens() {
        XCTAssertEqual(SearchQuery.parse("ray vmax"),
                       SearchQuery(nameTokens: ["ray", "vmax"], hp: nil, textPhrase: nil))
    }

    func testHPExactAndRanges() {
        XCTAssertEqual(SearchQuery.parse("hp:320").hp, .exact(320))
        XCTAssertEqual(SearchQuery.parse("hp:100-200").hp, .range(min: 100, max: 200))
        XCTAssertEqual(SearchQuery.parse("hp:100-").hp, .range(min: 100, max: nil))
        XCTAssertEqual(SearchQuery.parse("hp:-200").hp, .range(min: nil, max: 200))
        XCTAssertEqual(SearchQuery.parse("umbreon hp:200").nameTokens, ["umbreon"])
    }

    func testQuotedPhraseGoesToBody() {
        let q = SearchQuery.parse(#"pika "draw 3 cards" hp:60"#)
        XCTAssertEqual(q.textPhrase, "draw 3 cards")
        XCTAssertEqual(q.nameTokens, ["pika"])
        XCTAssertEqual(q.hp, .exact(60))
    }

    func testUnparseableHPBecomesNameToken() {
        let q = SearchQuery.parse("hp:banana")
        XCTAssertNil(q.hp)
        XCTAssertEqual(q.nameTokens, ["hp:banana"])
    }

    func testEmpty() {
        XCTAssertTrue(SearchQuery.parse("   ").isEmpty)
    }

    func testNumberSlashDenominator() {
        let q = SearchQuery.parse("charmander 58/112")
        XCTAssertEqual(q.number, CardNumberFilter(local: "58", total: 112))
        XCTAssertEqual(q.nameTokens, ["charmander"])
    }

    func testNumberHashNoTotal() {
        XCTAssertEqual(SearchQuery.parse("#58").number, CardNumberFilter(local: "58", total: nil))
    }

    func testNumberNormalizesZeroPadding() {
        // local is stored normalized (zero-stripped, uppercased); the search side normalizes the
        // column identically, so "008", "8", and "#08" all match a card numbered "008".
        XCTAssertEqual(SearchQuery.parse("008/102").number, CardNumberFilter(local: "8", total: 102))
    }

    func testBareDigitsAreNotANumberFilter() {
        // Ambiguous with a plain name/HP search — only the slash or "#" form counts.
        let q = SearchQuery.parse("58")
        XCTAssertNil(q.number)
        XCTAssertEqual(q.nameTokens, ["58"])
    }
}
