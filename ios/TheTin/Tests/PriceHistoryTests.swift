import XCTest
@testable import TheTin

final class PriceHistoryTests: XCTestCase {
    func testCatalogPriceHistoryReadsFromStore() async throws {
        let store = try CatalogStore(path: FixtureCatalog.copyToTemp())
        let provider = CatalogPriceHistory(store: store)
        let points = try await provider.rawHistory(cardId: "swsh7-215")
        XCTAssertEqual(points.map(\.value), [88.0, 90.5, 92.5])
        let none = try await provider.rawHistory(cardId: "swsh7-12")
        XCTAssertTrue(none.isEmpty)
    }
}
