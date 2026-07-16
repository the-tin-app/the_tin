import XCTest
import GRDB
@testable import TheTin

final class ForYouStreamTests: XCTestCase {
    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "cat-foryou-\(UUID().uuidString).sqlite"
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
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    /// set s1 = liked (7 non-full-art taste matches, distinct artists); set fa = UNPRICED full-art
    /// cards (not in taste — can only reach a page via explicit variety injection, never via the
    /// old top-priced experiment path); set ch = a high-priced chase card.
    private func makeVarietyStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "cat-variety-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, tcgplayer_id INTEGER);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, psa3 REAL, psa7 REAL, psa9 REAL, psa10 REAL, as_of TEXT);
            CREATE TABLE connected_art(scene_id TEXT, title TEXT, card_id TEXT, position INTEGER, PRIMARY KEY(scene_id, card_id));
            INSERT INTO card VALUES ('s1-1','s1','1','C1',60,'','Common','A1','i',1);
            INSERT INTO card VALUES ('s1-2','s1','2','C2',60,'','Common','A2','i',2);
            INSERT INTO card VALUES ('s1-3','s1','3','C3',60,'','Common','A3','i',3);
            INSERT INTO card VALUES ('s1-4','s1','4','C4',60,'','Common','A4','i',4);
            INSERT INTO card VALUES ('s1-5','s1','5','C5',60,'','Common','A5','i',5);
            INSERT INTO card VALUES ('s1-6','s1','6','C6',60,'','Common','A6','i',6);
            INSERT INTO card VALUES ('s1-7','s1','7','C7',60,'','Common','A7','i',7);
            INSERT INTO card VALUES ('fa-1','fa','1','Mewtwo',60,'','Illustration rare','ZZ','i',8);
            INSERT INTO card VALUES ('fa-2','fa','2','Mew',60,'','Special illustration rare','YY','i',9);
            INSERT INTO card VALUES ('ch-1','ch','1','Charizard',60,'','Rare Holo','XX','i',10);
            INSERT INTO price_latest VALUES ('ch-1',999.0,900.0,NULL,NULL,NULL,NULL,'2026-07-06');
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testPageInterleavesFullArtVariety() throws {
        // Profile likes set s1 (via an owned s1 card). The full-art cards are UNPRICED and not in
        // s1, so they can only appear if the stream deliberately injects full-art variety.
        let owned = CardRecord(id: "o1", setId: "s1", number: "0", name: "o", hp: nil, types: [],
                               rarity: "Common", artist: "A1", imageBase: nil, imageUrl: nil, tcgplayerId: nil)
        let profile = DiscoverAffinity.profile(owned: [owned], wanted: [], dexIds: [:])
        let stream = ForYouStream(store: try makeVarietyStore(), profile: profile, tasteIds: ["o1"])
        let page = stream.page(0)
        XCTAssertTrue(page.contains { DiscoverConstants.fullArtRarities.contains($0.rarity ?? "") },
                      "a For You page must interleave at least one full-art (SIR/IR) variety card")
    }

    func testColdStartUsesPopularMixWhenProfileEmpty() throws {
        let stream = ForYouStream(store: try makeStore(),
                                  profile: DiscoverAffinity.Profile(), tasteIds: [])
        XCTAssertFalse(stream.page(0).isEmpty, "empty profile still yields a popular mix")
    }

    func testLaterPagesWidenBucketDepth() throws {
        // bucketDepth grows with page index — page 1 must consider strictly more buckets than page 0.
        XCTAssertGreaterThan(ForYouStream.bucketDepth(forPage: 1),
                             ForYouStream.bucketDepth(forPage: 0))
    }

    func testExperimentCountIsAboutTwentyPercent() throws {
        // For a page of 10, expect ~2 experiment slots.
        XCTAssertEqual(ForYouStream.experimentSlots(pageSize: 10), 2)
    }
}
