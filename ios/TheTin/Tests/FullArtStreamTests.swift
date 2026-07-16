import XCTest
import GRDB
@testable import TheTin

final class FullArtStreamTests: XCTestCase {
    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "cat-fullart-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, tcgplayer_id INTEGER);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, psa3 REAL, psa7 REAL, psa9 REAL, psa10 REAL, as_of TEXT);
            CREATE TABLE connected_art(scene_id TEXT, title TEXT, card_id TEXT, position INTEGER, PRIMARY KEY(scene_id, card_id));

            -- full-art rarities (members of DiscoverConstants.fullArtRarities)
            INSERT INTO card VALUES ('s1-1','s1','1','Pikachu',60,'Lightning','Illustration rare','Ken Sugimori','img/s1-1',1);
            INSERT INTO card VALUES ('s1-2','s1','2','Raichu',120,'Lightning','Special illustration rare','Mitsuhiro Arita','img/s1-2',2);
            INSERT INTO card VALUES ('s1-3','s1','3','Eevee',50,'Colorless','Secret Rare','Mitsuhiro Arita','img/s1-3',3);
            INSERT INTO card VALUES ('s1-4','s1','4','Vaporeon',80,'Water','Ultra Rare','Atsuko Nishida','img/s1-4',4);
            INSERT INTO card VALUES ('s1-5','s1','5','Jolteon',90,'Lightning','Hyper rare','Atsuko Nishida','img/s1-5',5);
            INSERT INTO card VALUES ('s1-6','s1','6','Flareon',85,'Fire','Illustration rare','Ken Sugimori','img/s1-6',6);
            INSERT INTO card VALUES ('s1-7','s1','7','Espeon',65,'Psychic','Special illustration rare',NULL,'img/s1-7',7);
            INSERT INTO card VALUES ('s1-8','s1','8','Umbreon',95,'Darkness','Secret Rare','Ken Sugimori','img/s1-8',8);

            -- non-full-art rarities (must never appear in the stream)
            INSERT INTO card VALUES ('s1-9','s1','9','Bulbasaur',45,'Grass','Common','Ken Sugimori','img/s1-9',9);
            INSERT INTO card VALUES ('s1-10','s1','10','Ivysaur',60,'Grass','Rare','Mitsuhiro Arita','img/s1-10',10);
            INSERT INTO card VALUES ('s1-11','s1','11','Venusaur',80,'Grass','Uncommon',NULL,'img/s1-11',11);
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testOnlyFullArtRaritiesAppear() throws {
        let stream = FullArtStream(store: try makeStore(), seed: 42, pageSize: 100)
        let all = (0..<3).flatMap { stream.page($0) }

        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.allSatisfy { DiscoverConstants.fullArtRarities.contains($0.rarity ?? "") })
        // Non-full-art rows must never leak into the stream.
        XCTAssertFalse(all.map(\.id).contains(where: ["s1-9", "s1-10", "s1-11"].contains))
        // Every full-art row shows up exactly once (single page covers the whole candidate set).
        XCTAssertEqual(Set(all.map(\.id)), ["s1-1", "s1-2", "s1-3", "s1-4", "s1-5", "s1-6", "s1-7", "s1-8"])
    }

    func testShuffleIsDeterministicForSeed() throws {
        let s = try makeStore()
        let a = FullArtStream(store: s, seed: 7, pageSize: 5).page(0).map(\.id)
        let b = FullArtStream(store: s, seed: 7, pageSize: 5).page(0).map(\.id)
        XCTAssertEqual(a, b, "same seed → same order")
    }
}
