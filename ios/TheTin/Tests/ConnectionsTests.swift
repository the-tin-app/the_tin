import XCTest
import GRDB
@testable import TheTin

final class ConnectionsTests: XCTestCase {
    /// Temp SQLite matching the CURRENT shipped schema: `connected_art` has NO `kind` column
    /// (Task 11 adds it later), so `curatedConnections()` must fall back to kind="combined".
    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "conn-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, tcgplayer_id INTEGER);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, psa3 REAL, psa7 REAL, psa9 REAL, psa10 REAL, as_of TEXT);
            CREATE TABLE connected_art(scene_id TEXT, title TEXT, card_id TEXT, position INTEGER, PRIMARY KEY(scene_id, card_id));
            -- Curated scene (no `kind` column at all -- exercises the fallback-to-combined path)
            INSERT INTO connected_art VALUES ('scene-a','Night Picnic','s1-1',0);
            INSERT INTO connected_art VALUES ('scene-a','Night Picnic','s1-2',1);
            -- Artist with >=2 cards -> artist spotlight
            INSERT INTO card VALUES ('s1-1','s1','1','Pikachu',60,'Lightning','Rare','Ken Sugimori','img/s1-1',1);
            INSERT INTO card VALUES ('s1-2','s1','2','Raichu',120,'Lightning','Rare','Ken Sugimori','img/s1-2',2);
            -- Artist with exactly 1 card -> must NOT produce a spotlight
            INSERT INTO card VALUES ('s1-3','s1','3','Eevee',50,'Colorless','Common','Mitsuhiro Arita','img/s1-3',3);
            -- Gallery-prefixed cards (>=2) -> gallery group
            INSERT INTO card VALUES ('s1-TG01','s1','TG01','Gengar',130,'Psychic','Rare','Mina Nakai','img/s1-tg01',4);
            INSERT INTO card VALUES ('s1-TG02','s1','TG02','Gastly',60,'Psychic','Rare','Mina Nakai','img/s1-tg02',5);
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testCuratedConnectionsFallsBackToCombinedWhenKindColumnAbsent() throws {
        let store = try makeStore()
        let curated = try store.curatedConnections()
        XCTAssertEqual(curated.count, 1)
        XCTAssertEqual(curated.first?.kind, "combined")
        XCTAssertEqual(curated.first?.cardIds, ["s1-1", "s1-2"])
    }

    func testBuildIncludesCuratedCombinedScenes() throws {
        let connections = ConnectionsBuilder.build(store: try makeStore())
        XCTAssertTrue(connections.contains { $0.kind == .combinedArt })
    }

    func testArtistSpotlightsHaveAtLeastTwoCards() throws {
        let connections = ConnectionsBuilder.build(store: try makeStore())
        let spotlights = connections.filter { $0.kind == .artistSpotlight }
        XCTAssertFalse(spotlights.isEmpty, "expected at least one artist spotlight from Ken Sugimori (2 cards)")
        for c in spotlights {
            XCTAssertGreaterThanOrEqual(c.cardIds.count, 2, "a spotlight of one card is not a group")
        }
        // The single-card artist (Mitsuhiro Arita) must not produce a spotlight.
        XCTAssertFalse(spotlights.contains { $0.cardIds.contains("s1-3") })
    }

    func testBuildIncludesGalleryGroupWithAtLeastTwoCards() throws {
        let connections = ConnectionsBuilder.build(store: try makeStore())
        let galleries = connections.filter { $0.kind == .gallery }
        XCTAssertFalse(galleries.isEmpty)
        for g in galleries {
            XCTAssertGreaterThanOrEqual(g.cardIds.count, 2)
        }
    }
}
