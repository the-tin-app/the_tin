import XCTest
import GRDB
@testable import TheTin

final class CatalogStoreSealedTests: XCTestCase {
    private func makeStore(withTable: Bool) throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "sealed-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            if withTable {
                try db.execute(sql: """
                CREATE TABLE sealed_product(tcgplayer_id INTEGER PRIMARY KEY, name TEXT NOT NULL, set_id TEXT,
                  product_type TEXT, market_usd REAL, low_usd REAL, as_of TEXT);
                INSERT INTO sealed_product VALUES (100,'Set One ETB','s1','Elite Trainer Box',49.99,44.0,'2026-07-08');
                INSERT INTO sealed_product VALUES (101,'Set One Booster Box','s1','Booster Box',119.99,110.0,'2026-07-08');
                INSERT INTO sealed_product VALUES (102,'Set Two Booster Pack','s2','Booster Pack',4.50,NULL,'2026-07-08');
                """)
            } else {
                try db.execute(sql: "CREATE TABLE card(id TEXT PRIMARY KEY);") // catalog with no sealed_product
            }
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testSealedProductsForSet_mapsColumns_alphabetical() throws {
        let store = try makeStore(withTable: true)
        let s1 = try store.sealedProducts(setId: "s1")
        XCTAssertEqual(s1.map(\.name), ["Set One Booster Box", "Set One ETB"]) // ORDER BY name
        let box = try XCTUnwrap(s1.first)
        XCTAssertEqual(box.tcgplayerId, 101)
        XCTAssertEqual(box.productType, "Booster Box")
        XCTAssertEqual(box.marketUsd, 119.99)
        XCTAssertEqual(box.lowUsd, 110.0)
    }

    func testAllSealedProducts_includesEverySet_nullLowStaysNil() throws {
        let store = try makeStore(withTable: true)
        let all = try store.allSealedProducts()
        XCTAssertEqual(all.count, 3)
        let pack = try XCTUnwrap(all.first { $0.tcgplayerId == 102 })
        XCTAssertNil(pack.lowUsd)
        XCTAssertEqual(pack.setId, "s2")
    }

    /// A catalog built before the sealed_product table must not crash — the query throws and
    /// call sites fall back to [] via try?.
    func testMissingTable_throws_soCallSitesGetEmpty() throws {
        let store = try makeStore(withTable: false)
        XCTAssertThrowsError(try store.allSealedProducts())
        XCTAssertNil(try? store.sealedProducts(setId: "s1"))
    }
}
