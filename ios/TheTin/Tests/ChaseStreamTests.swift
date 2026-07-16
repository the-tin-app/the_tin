import XCTest
import GRDB
@testable import TheTin

final class ChaseStreamTests: XCTestCase {
    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "cat-chase-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, tcgplayer_id INTEGER);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, psa3 REAL, psa7 REAL, psa9 REAL, psa10 REAL, as_of TEXT);
            CREATE TABLE connected_art(scene_id TEXT, title TEXT, card_id TEXT, position INTEGER, PRIMARY KEY(scene_id, card_id));

            INSERT INTO card VALUES ('s1-1','s1','1','Pikachu',60,'Lightning','Rare','Ken Sugimori','img/s1-1',1);
            INSERT INTO card VALUES ('s1-2','s1','2','Raichu',120,'Lightning','Rare','Ken Sugimori','img/s1-2',2);
            INSERT INTO card VALUES ('s1-3','s1','3','Eevee',50,'Colorless','Common','Mitsuhiro Arita','img/s1-3',3);
            INSERT INTO card VALUES ('s1-4','s1','4','Vaporeon',80,'Water','Rare','Atsuko Nishida','img/s1-4',4);
            INSERT INTO card VALUES ('s1-5','s1','5','Jolteon',90,'Lightning','Rare','Atsuko Nishida','img/s1-5',5);
            INSERT INTO card VALUES ('s1-6','s1','6','Flareon',85,'Fire','Rare','Ken Sugimori','img/s1-6',6);

            -- distinct raw_usd so the price-sorted order is unambiguous:
            --   s1-5(100) > s1-6(75) > s1-2(50) > s1-1(30) > s1-4(20); s1-3 null (excluded)
            INSERT INTO price_latest VALUES ('s1-1',30.0,24.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-2',50.0,40.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-3',NULL,NULL,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-4',20.0,16.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-5',100.0,80.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-6',75.0,60.0,NULL,NULL,NULL,NULL,'2026-07-06');
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testChasePagesMapToPricedOffsets() throws {
        let store = try makeStore()
        let stream = ChaseStream(store: store, pageSize: 1)

        let expected0 = try store.topPricedCards(offset: 0, limit: 1)
        XCTAssertEqual(stream.page(0).map(\.id), expected0.map(\.id))
        XCTAssertEqual(stream.page(0).map(\.id), ["s1-5"], "highest raw_usd (100) first")
    }

    /// With pageSize > 1, page(index) must map to offset index*pageSize — not just index.
    /// page(1) here is the 3rd/4th priced cards; an `offset: index` regression would instead
    /// return the offset-1 slice (2nd/3rd), so this test genuinely exercises the multiplication.
    func testChasePageOffsetIsIndexTimesPageSize() throws {
        let store = try makeStore()
        let stream = ChaseStream(store: store, pageSize: 2)

        let page0 = stream.page(0)
        let page1 = stream.page(1)

        // offset 0 slice = top two priced
        XCTAssertEqual(page0.map(\.id), ["s1-5", "s1-6"], "100, 75")
        XCTAssertEqual(page0.map(\.id), try store.topPricedCards(offset: 0, limit: 2).map(\.id))

        // offset 2 slice = 3rd/4th priced — NOT the offset-1 slice (s1-6, s1-2)
        XCTAssertEqual(page1.map(\.id), ["s1-2", "s1-1"], "50, 30 — proves offset = 1*2, not 1")
        XCTAssertEqual(page1.map(\.id), try store.topPricedCards(offset: 2, limit: 2).map(\.id))

        let ids = (page0 + page1).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no overlap between consecutive pages")
    }
}
