import XCTest
import GRDB
@testable import TheTin

final class CatalogStoreBrowseTests: XCTestCase {
    /// Store fixture: two eras, mixed rarities/types/prices, and price_delta rows for deals.
    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "browse-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, image_url TEXT, tcgplayer_id INTEGER, attacks TEXT);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, as_of TEXT);
            CREATE TABLE price_delta(card_id TEXT, kind TEXT, key TEXT, pct_1d REAL, pct_7d REAL, pct_30d REAL);
            INSERT INTO set_info VALUES ('sv1','Scarlet Base','2023-03-31',200,'Scarlet & Violet','sv1-1');
            INSERT INTO set_info VALUES ('swsh1','Sword Base','2020-02-07',200,'Sword & Shield','swsh1-1');
            -- id, set, num, name, hp, types, rarity, artist, image_base, image_url, tcgId, attacks
            INSERT INTO card VALUES ('sv1-1','sv1','1','Sprigatito',60,'Grass','Illustration rare','A','img/sv1-1',NULL,10,NULL);
            INSERT INTO card VALUES ('sv1-2','sv1','2','Charizard',180,'Fire,Colorless','Secret Rare','B','img/sv1-2',NULL,11,NULL);
            INSERT INTO card VALUES ('sv1-3','sv1','3','Magikarp',30,'Water','Common','C','img/sv1-3',NULL,12,NULL);
            INSERT INTO card VALUES ('swsh1-1','swsh1','1','Grookey',70,'Grass','Ultra Rare','D','img/swsh1-1',NULL,13,NULL);
            INSERT INTO price_latest VALUES ('sv1-1',8.0,7.0,'2026-07-06');
            INSERT INTO price_latest VALUES ('sv1-2',120.0,110.0,'2026-07-06');
            INSERT INTO price_latest VALUES ('sv1-3',NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('swsh1-1',25.0,20.0,'2026-07-06');
            INSERT INTO price_delta VALUES ('sv1-2','raw','',-2.0,-12.0,-20.0); -- a deal (7d < -5)
            INSERT INTO price_delta VALUES ('sv1-1','raw','',1.0,3.0,4.0);       -- not a deal
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testEraFilter() throws {
        let store = try makeStore()
        var c = BrowseCriteria(); c.eras = ["Sword & Shield"]
        XCTAssertEqual(try store.browse(criteria: c, ownedIds: [], offset: 0, limit: 50).map(\.id), ["swsh1-1"])
    }

    func testRarityFilter() throws {
        let store = try makeStore()
        var c = BrowseCriteria(); c.rarities = ["Secret Rare", "Ultra Rare"]
        XCTAssertEqual(try store.browse(criteria: c, ownedIds: [], offset: 0, limit: 50).map(\.id).sorted(), ["sv1-2", "swsh1-1"])
    }

    func testTypeFilterIsDelimiterSafe() throws {
        let store = try makeStore()
        var c = BrowseCriteria(); c.types = ["Fire"] // sv1-2 has "Fire,Colorless"
        XCTAssertEqual(try store.browse(criteria: c, ownedIds: [], offset: 0, limit: 50).map(\.id), ["sv1-2"])
        var g = BrowseCriteria(); g.types = ["Grass"]
        XCTAssertEqual(try store.browse(criteria: g, ownedIds: [], offset: 0, limit: 50).map(\.id).sorted(), ["sv1-1", "swsh1-1"])
    }

    func testPriceBandExcludesNullAndOutOfRange() throws {
        let store = try makeStore()
        var c = BrowseCriteria(); c.minPrice = 10; c.maxPrice = 100 // only swsh1-1 (25)
        XCTAssertEqual(try store.browse(criteria: c, ownedIds: [], offset: 0, limit: 50).map(\.id), ["swsh1-1"])
    }

    func testPriceSortAscending() throws {
        let store = try makeStore()
        var c = BrowseCriteria(); c.sort = .priceAsc // null-price sv1-3 excluded by the price join
        XCTAssertEqual(try store.browse(criteria: c, ownedIds: [], offset: 0, limit: 50).map(\.id), ["sv1-1", "swsh1-1", "sv1-2"])
    }

    func testDealsOnly() throws {
        let store = try makeStore()
        var c = BrowseCriteria(); c.dealsOnly = true
        XCTAssertEqual(try store.browse(criteria: c, ownedIds: [], offset: 0, limit: 50).map(\.id), ["sv1-2"])
    }

    func testHideOwned() throws {
        let store = try makeStore()
        var c = BrowseCriteria(); c.hideOwned = true
        let ids = try store.browse(criteria: c, ownedIds: ["sv1-2"], offset: 0, limit: 50).map(\.id)
        XCTAssertFalse(ids.contains("sv1-2"))
        XCTAssertTrue(ids.contains("sv1-1"))
    }

    func testPagingIsStableAndNonOverlapping() throws {
        let store = try makeStore()
        let c = BrowseCriteria() // all 4 cards, id order
        let p0 = try store.browse(criteria: c, ownedIds: [], offset: 0, limit: 2).map(\.id)
        let p1 = try store.browse(criteria: c, ownedIds: [], offset: 2, limit: 2).map(\.id)
        XCTAssertEqual(p0.count, 2)
        XCTAssertTrue(Set(p0).isDisjoint(with: Set(p1)))
    }

    func testDistinctErasNewestFirst() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.distinctEras(), ["Scarlet & Violet", "Sword & Shield"]) // 2023 before 2020
    }
}
