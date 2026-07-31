import XCTest
import GRDB
@testable import TheTin

final class BrowseStreamTests: XCTestCase {
    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "bstream-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, image_url TEXT, tcgplayer_id INTEGER, attacks TEXT);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, as_of TEXT);
            CREATE TABLE price_delta(card_id TEXT, kind TEXT, key TEXT, pct_1d REAL, pct_7d REAL, pct_30d REAL);
            INSERT INTO set_info VALUES ('sv1','Scarlet Base','2023-03-31',200,'Scarlet & Violet','sv1-1');
            INSERT INTO card VALUES ('sv1-1','sv1','1','A',60,'Grass','Common',NULL,'i',NULL,1,NULL);
            INSERT INTO card VALUES ('sv1-2','sv1','2','B',60,'Fire','Common',NULL,'i',NULL,2,NULL);
            INSERT INTO card VALUES ('sv1-3','sv1','3','C',60,'Water','Common',NULL,'i',NULL,3,NULL);
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testPagesInOrderAndDedupBoundary() throws {
        let store = try makeStore()
        let stream = BrowseStream(store: store, criteria: BrowseCriteria(), ownedIds: [], pageSize: 2)
        XCTAssertEqual(stream.page(0).map(\.id), ["sv1-1", "sv1-2"])
        XCTAssertEqual(stream.page(1).map(\.id), ["sv1-3"])
        XCTAssertTrue(stream.page(2).isEmpty)
    }
}
