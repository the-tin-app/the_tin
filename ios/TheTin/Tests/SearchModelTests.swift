import XCTest
@testable import TheTin

@MainActor
final class SearchModelTests: XCTestCase {
    private var store: CatalogStore!
    private var model: SearchModel!

    override func setUpWithError() throws {
        store = try CatalogStore(path: try FixtureCatalog.copyToTemp())
        model = SearchModel(store: store)
    }

    override func tearDownWithError() throws { try store?.close() }

    func testTypingRunsSearchAndLoadsPrices() {
        model.text = "ray"
        XCTAssertEqual(model.results.map(\.id), ["swsh7-215"])
        XCTAssertEqual(model.prices["swsh7-215"]?.rawUsd, 92.5)
    }

    func testClearingTextClearsResults() {
        model.text = "ray"
        model.text = ""
        XCTAssertTrue(model.results.isEmpty)
    }

    func testHPFilterQuery() {
        model.text = "hp:60"
        XCTAssertEqual(model.results.map(\.id), ["sv1-25"])
    }
}
