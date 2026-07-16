import XCTest
import GRDB
@testable import TheTin

final class CatalogStoreV3Tests: XCTestCase {
    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "cat-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, tcgplayer_id INTEGER);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, psa3 REAL, psa7 REAL, psa9 REAL, psa10 REAL, as_of TEXT);
            CREATE TABLE pokemon(dex_id INTEGER PRIMARY KEY, name TEXT, rep_card_id TEXT);
            CREATE TABLE card_dex(card_id TEXT, dex_id INTEGER, PRIMARY KEY(card_id, dex_id));
            INSERT INTO set_info VALUES ('s1','Set One','2020-01-01',2,'Sword & Shield','s1-2');
            INSERT INTO card VALUES ('s1-1','s1','1','Pikachu',60,'Lightning','Rare','X','img/s1-1',1);
            INSERT INTO card VALUES ('s1-2','s1','2','Pikachu V',190,'Lightning','Ultra','Y','img/s1-2',2);
            INSERT INTO price_latest VALUES ('s1-1',5.0,4.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-2',20.0,18.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO pokemon VALUES (25,'Pikachu','s1-2');
            INSERT INTO card_dex VALUES ('s1-1',25); INSERT INTO card_dex VALUES ('s1-2',25);
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testSetRecordHasRepCardId() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.set(id: "s1")?.repCardId, "s1-2")
    }
    func testPokemonList() throws {
        let store = try makeStore()
        let list = try store.pokemon()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.name, "Pikachu")
        XCTAssertEqual(list.first?.repCardId, "s1-2")
    }
    func testCardsForDex() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.cards(forDex: 25).map(\.id).sorted(), ["s1-1","s1-2"])
    }
    func testSetRawTotals() throws {
        let store = try makeStore()
        let total = try XCTUnwrap(store.setRawTotals()["s1"])
        XCTAssertEqual(total, 25.0, accuracy: 0.001)
    }
}
