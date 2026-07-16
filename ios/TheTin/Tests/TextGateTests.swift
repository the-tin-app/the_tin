import XCTest
@testable import TheTin

final class TextGateTests: XCTestCase {
    func testParseCollectorNumber() {
        XCTAssertEqual(CollectorNumber.parse("025/165"), ParsedNumber(number: "25", total: 165))
        XCTAssertEqual(CollectorNumber.parse("  25 / 165 "), ParsedNumber(number: "25", total: 165))
        XCTAssertNil(CollectorNumber.parse("no number here"))
    }

    func testCandidateIndexGatesByNumberAndTotal() throws {
        // FixtureCatalog builds a small in-memory CatalogStore (see ios/TheTin/Tests/FixtureCatalog.swift).
        let store = try FixtureCatalog.make()
        let index = try CandidateIndex(store: store)
        let ids = index.candidates(number: FixtureCatalog.knownNumber,
                                   total: FixtureCatalog.knownTotal, name: nil)
        XCTAssertTrue(ids.contains(FixtureCatalog.knownCardId))
        XCTAssertFalse(index.candidates(number: "9999", total: 1, name: nil).contains(FixtureCatalog.knownCardId))
    }
}
