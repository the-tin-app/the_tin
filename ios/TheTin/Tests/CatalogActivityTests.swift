import XCTest
@testable import TheTin

@MainActor
final class CatalogActivityTests: XCTestCase {
    override func setUp() async throws {
        CatalogActivity.url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("activity.log")
    }

    func testRecordsNewestFirstAndCaps() {
        for i in 1...(CatalogActivity.cap + 10) { CatalogActivity.record("event \(i)") }
        let lines = CatalogActivity.read()
        XCTAssertEqual(lines.count, CatalogActivity.cap)
        XCTAssertTrue(lines.first!.hasSuffix("event \(CatalogActivity.cap + 10)"))
        XCTAssertTrue(lines.last!.hasSuffix("event 11"))
    }
}
