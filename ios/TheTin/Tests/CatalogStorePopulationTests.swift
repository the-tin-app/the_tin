import XCTest
import GRDB
@testable import TheTin

final class CatalogStorePopulationTests: XCTestCase {
    private func makeStore(withTable: Bool) throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "pop-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            if withTable {
                try db.execute(sql: """
                CREATE TABLE population(card_id TEXT NOT NULL, grader TEXT NOT NULL, grade TEXT NOT NULL,
                  count INTEGER, gem_rate REAL, total_population INTEGER, as_of TEXT NOT NULL,
                  PRIMARY KEY(card_id, grader, grade));
                INSERT INTO population VALUES ('c1','PSA','9',900,0.42,5000,'2026-07-11');
                INSERT INTO population VALUES ('c1','PSA','10',2100,0.42,5000,'2026-07-11');
                INSERT INTO population VALUES ('c1','PSA','9.5',3,0.42,5000,'2026-07-11');
                INSERT INTO population VALUES ('c1','BGS','10',12,NULL,60,'2026-07-11');
                """)
            } else {
                try db.execute(sql: "CREATE TABLE card(id TEXT PRIMARY KEY);")
            }
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testPopulation_psaOnly_highestGradeFirst_mapsColumns() throws {
        let store = try makeStore(withTable: true)
        let rows = try store.population(cardId: "c1")
        XCTAssertEqual(rows.map(\.grade), ["10", "9.5", "9"]) // ORDER BY CAST(grade AS REAL) DESC, PSA only
        let top = try XCTUnwrap(rows.first)
        XCTAssertEqual(top.count, 2100)
        XCTAssertEqual(top.gemRate, 0.42)
        XCTAssertEqual(top.totalPopulation, 5000)
    }

    func testPopulation_missingTable_throws_soCallSitesGetEmpty() throws {
        let store = try makeStore(withTable: false)
        XCTAssertNil(try? store.population(cardId: "c1"))
    }

    func testDisplayGrade_normalizesGPrefixAndUnderscore() {
        func grade(_ g: String) -> String {
            PopulationRow(grader: "PSA", grade: g, count: 0, gemRate: nil, totalPopulation: nil).displayGrade
        }
        XCTAssertEqual(grade("g10"), "10")
        XCTAssertEqual(grade("9_5"), "9.5")   // the reported "PSA 4_5" bug
        XCTAssertEqual(grade("9.5"), "9.5")
    }
}
