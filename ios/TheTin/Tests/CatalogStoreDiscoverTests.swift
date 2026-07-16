import XCTest
import GRDB
@testable import TheTin

final class CatalogStoreDiscoverTests: XCTestCase {
    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "cat-\(UUID().uuidString).sqlite"
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
            INSERT INTO price_latest VALUES ('s1-1',5.0,4.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-2',50.0,40.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-3',NULL,NULL,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO connected_art VALUES ('scene-a','Night Picnic','s1-2',1);
            INSERT INTO connected_art VALUES ('scene-a','Night Picnic','s1-1',0);
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testCardsByArtist() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.cards(byArtist: "Ken Sugimori").map(\.id).sorted(), ["s1-1","s1-2"])
        XCTAssertEqual(try store.cards(byArtist: "Nobody").count, 0)
    }

    func testTopPricedCardsExcludesNullAndOrdersDesc() throws {
        let store = try makeStore()
        let top = try store.topPricedCards(limit: 10)
        XCTAssertEqual(top.map(\.id), ["s1-2","s1-1"]) // 50 before 5; s1-3 (null raw_usd) excluded
    }

    func testConnectedArtScenesGroupedAndOrderedByPosition() throws {
        let store = try makeStore()
        let scenes = try store.connectedArtScenes()
        XCTAssertEqual(scenes.count, 1)
        XCTAssertEqual(scenes.first?.sceneId, "scene-a")
        XCTAssertEqual(scenes.first?.title, "Night Picnic")
        XCTAssertEqual(scenes.first?.cardIds, ["s1-1","s1-2"]) // position 0 then 1
    }
}
