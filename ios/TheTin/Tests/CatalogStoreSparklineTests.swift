import XCTest
import GRDB
@testable import TheTin

/// Casual catalog tier ships `price_history` present but empty (schema-only, zero rows).
/// Locks in that `priceHistory(cardId:)` degrades to `[]` for that case instead of throwing/crashing.
final class CatalogStoreSparklineTests: XCTestCase {
    func testEmptyPriceHistoryReturnsNoPointsAndDoesNotThrow() throws {
        let path = NSTemporaryDirectory() + "casual-\(UUID().uuidString).sqlite"
        let db = try DatabaseQueue(path: path)
        try db.write { d in
            try d.execute(sql: """
                CREATE TABLE card(id TEXT PRIMARY KEY, name TEXT);
                CREATE TABLE price_history(card_id TEXT NOT NULL, date TEXT NOT NULL, raw_usd REAL NOT NULL);
                INSERT INTO card VALUES ('c1','Pikachu');
            """)
        }
        let store = try CatalogStore(path: path)
        let points = try store.priceHistory(cardId: "c1")
        XCTAssertTrue(points.isEmpty)
        try? FileManager.default.removeItem(atPath: path)
    }
}
