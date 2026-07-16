import XCTest
import GRDB
@testable import TheTin

final class CatalogStoreStreamTests: XCTestCase {
    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "cat-stream-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, tcgplayer_id INTEGER);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, psa3 REAL, psa7 REAL, psa9 REAL, psa10 REAL, as_of TEXT);
            CREATE TABLE connected_art(scene_id TEXT, title TEXT, card_id TEXT, position INTEGER, PRIMARY KEY(scene_id, card_id));

            -- rarity fixtures: two full-art (Illustration rare), rest non-full-art
            INSERT INTO card VALUES ('s1-1','s1','1','Pikachu',60,'Lightning','Illustration rare','Ken Sugimori','img/s1-1',1);
            INSERT INTO card VALUES ('s1-2','s1','2','Raichu',120,'Lightning','Illustration rare','Mitsuhiro Arita','img/s1-2',2);
            INSERT INTO card VALUES ('s1-3','s1','3','Eevee',50,'Colorless','Common','Mitsuhiro Arita','img/s1-3',3);
            INSERT INTO card VALUES ('s1-4','s1','4','Vaporeon',80,'Water','Rare','Atsuko Nishida','img/s1-4',4);

            -- price fixtures: 3 distinct non-null prices + 1 null (excluded)
            INSERT INTO card VALUES ('s1-5','s1','5','Jolteon',90,'Lightning','Rare','Atsuko Nishida','img/s1-5',5);
            INSERT INTO card VALUES ('s1-6','s1','6','Flareon',85,'Fire','Rare',NULL,'img/s1-6',6);
            INSERT INTO price_latest VALUES ('s1-4',10.0,8.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-5',30.0,24.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-6',20.0,16.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-1',NULL,NULL,NULL,NULL,NULL,NULL,'2026-07-06');

            -- gallery fixtures: TG/GG-prefixed numbers plus normal-numbered rows
            INSERT INTO card VALUES ('s1-TG01','s1','TG01','Mew',30,'Psychic','Trainer Gallery Rare',NULL,'img/s1-TG01',7);
            INSERT INTO card VALUES ('s1-TG02','s1','TG02','Celebi',50,'Grass','Trainer Gallery Rare',NULL,'img/s1-TG02',8);
            INSERT INTO card VALUES ('s1-GG01','s1','GG01','Arceus',100,'Colorless','Galarian Gallery Rare',NULL,'img/s1-GG01',9);
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testMatchingRaritiesFiltersToRequestedSet() throws {
        let store = try makeStore()
        let cards = try store.cards(matchingRarities: ["Illustration rare"])
        XCTAssertEqual(Set(cards.map(\.id)), ["s1-1", "s1-2"])
        XCTAssertTrue(cards.allSatisfy { $0.rarity == "Illustration rare" })
    }

    func testMatchingRaritiesEmptySetReturnsEmpty() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.cards(matchingRarities: []), [])
    }

    func testTopPricedPagingIsStrictlyDescendingAcrossPages() throws {
        let store = try makeStore()
        let page0 = try store.topPricedCards(offset: 0, limit: 2)
        let page1 = try store.topPricedCards(offset: 2, limit: 2)

        XCTAssertEqual(page0.map(\.id), ["s1-5", "s1-6"]) // 30, 20
        XCTAssertEqual(page1.map(\.id), ["s1-4"]) // 10; s1-1's null raw_usd excluded

        let ids = (page0 + page1).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no card repeats across pages")

        // strictly descending by raw_usd across the combined pages
        let priceStore = try store.prices(cardIds: ids)
        let prices = ids.compactMap { priceStore[$0]?.rawUsd }
        XCTAssertEqual(prices, prices.sorted(by: >))
    }

    func testGalleryCardsGroupsOnlyTGAndGGPrefixedNumbers() throws {
        let store = try makeStore()
        let groups = try store.galleryCards()

        let allGroupedIds = Set(groups.values.flatMap { $0.map(\.id) })
        XCTAssertEqual(allGroupedIds, ["s1-TG01", "s1-TG02", "s1-GG01"])
        XCTAssertFalse(allGroupedIds.contains("s1-1"))

        XCTAssertEqual(groups["s1/TG"]?.map(\.id), ["s1-TG01", "s1-TG02"])
        XCTAssertEqual(groups["s1/GG"]?.map(\.id), ["s1-GG01"])
    }

    func testTopArtistsReturnsOnlyNonEmptyArtists() throws {
        let store = try makeStore()
        let artists = try store.topArtists(limit: 5)

        // Atsuko Nishida has 2 cards (s1-4, s1-5), so ranks first; NULL-artist rows never appear.
        XCTAssertEqual(artists.first, "Atsuko Nishida")
        XCTAssertFalse(artists.contains(""))
        XCTAssertTrue(Set(artists).isSubset(of: ["Mitsuhiro Arita", "Ken Sugimori", "Atsuko Nishida"]))
    }
}
