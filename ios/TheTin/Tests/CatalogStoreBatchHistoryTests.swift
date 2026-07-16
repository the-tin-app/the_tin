import XCTest
import GRDB
@testable import TheTin

/// Locks in the batch history query Task 6 (PortfolioModel) depends on: one `IN` query,
/// grouped by card, oldest-first, absent key for cards with no rows.
final class CatalogStoreBatchHistoryTests: XCTestCase {
    func testBatchPriceHistoryGroupsByCardOldestFirst() throws {
        let path = NSTemporaryDirectory() + "hist-\(UUID().uuidString).sqlite"
        let db = try DatabaseQueue(path: path)
        try db.write { d in
            try d.execute(sql: """
                CREATE TABLE price_history(card_id TEXT NOT NULL, date TEXT NOT NULL, raw_usd REAL NOT NULL);
                INSERT INTO price_history VALUES ('c1','2026-07-01',10.0);
                INSERT INTO price_history VALUES ('c1','2026-06-24',9.0);
                INSERT INTO price_history VALUES ('c2','2026-07-01',5.0);
            """)
        }
        let store = try CatalogStore(path: path)
        let out = try store.priceHistory(cardIds: ["c1", "c2", "c3"])
        XCTAssertEqual(out["c1"]?.map(\.value), [9.0, 10.0])   // oldest first
        XCTAssertEqual(out["c2"]?.map(\.value), [5.0])
        XCTAssertNil(out["c3"])                                 // no rows → absent, not []
        XCTAssertEqual(try store.priceHistory(cardIds: []), [:])
        try? FileManager.default.removeItem(atPath: path)
    }
}
