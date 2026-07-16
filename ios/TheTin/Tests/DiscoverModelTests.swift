import XCTest
import GRDB
@testable import TheTin

final class DiscoverModelTests: XCTestCase {
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
            CREATE TABLE connected_art(scene_id TEXT, title TEXT, card_id TEXT, position INTEGER, PRIMARY KEY(scene_id, card_id));
            INSERT INTO set_info VALUES ('s1','Set One','2020-01-01',3,'E1','s1-2');
            INSERT INTO set_info VALUES ('s2','Set Two','2024-01-01',1,'E2','s2-1');
            INSERT INTO card VALUES ('s1-1','s1','1','Pikachu',60,'Lightning','Rare','K','img/s1-1',1);
            INSERT INTO card VALUES ('s1-2','s1','2','Raichu',120,'Lightning','Rare','K','img/s1-2',2);
            INSERT INTO card VALUES ('s1-3','s1','3','Eevee',50,'Colorless','Common','A','img/s1-3',3);
            INSERT INTO card VALUES ('s2-1','s2','1','Mew',60,'Psychic','Rare','A','img/s2-1',4);
            INSERT INTO price_latest VALUES ('s1-1',5.0,4.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-2',50.0,40.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s2-1',30.0,20.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO pokemon VALUES (25,'Pikachu','s1-2');
            INSERT INTO card_dex VALUES ('s1-1',25); INSERT INTO card_dex VALUES ('s1-2',25);
            INSERT INTO connected_art VALUES ('scene-a','Duo','s1-1',0);
            INSERT INTO connected_art VALUES ('scene-a','Duo','s1-2',1);
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    /// Cold start: no owned/wanted signal still yields a populated home — a popular For You
    /// preview and the curated `scene-a` combined-art Connection.
    @MainActor
    func testColdStartHasPopularForYouAndCuratedConnection() async throws {
        let store = try makeStore()
        let model = DiscoverModel(store: store)
        await model.load(ownedIds: [], wantedIds: [])

        XCTAssertTrue(model.isLoaded)
        // No taste signal -> ForYou falls back to a popular/high-value mix, never empty.
        XCTAssertFalse(model.previews[.forYou, default: []].isEmpty,
                       "cold-start For You preview should carry the popular mix")
        // Curated art scene surfaces as a combinedArt Connection.
        XCTAssertFalse(model.connections.isEmpty)
        XCTAssertTrue(model.connections.contains { $0.id == "scene-a" && $0.kind == .combinedArt },
                      "expected curated scene-a as a combined-art connection")
    }

    /// Headline recompute-on-change: with no latch, a new taste signal (owning s1-1) rebuilds the
    /// For You preview. Cold start includes s1-1 (it is priced, so it appears in the popular mix);
    /// after owning it, the preview must EXCLUDE the owned card and INCLUDE its same-set/artist/species
    /// sibling s1-2 — proving the profile-driven rebuild actually reflects the new signal.
    @MainActor
    func testForYouRecomputesWhenOwnedChanges() async throws {
        let store = try makeStore()
        let model = DiscoverModel(store: store)

        await model.load(ownedIds: [], wantedIds: [])
        let before = model.previews[.forYou, default: []].map(\.id)
        // Precondition that makes the after-assertion discriminating: the popular cold-start mix
        // contains s1-1, so its later absence can only come from a genuine recompute.
        XCTAssertTrue(before.contains("s1-1"), "cold-start popular mix should include priced s1-1")

        await model.load(ownedIds: ["s1-1"], wantedIds: [])
        let after = model.previews[.forYou, default: []].map(\.id)

        XCTAssertNotEqual(before, after, "For You preview must rebuild on a taste-signal change")
        XCTAssertFalse(after.contains("s1-1"), "owned card must be excluded after recompute")
        XCTAssertTrue(after.contains("s1-2"),
                      "recompute should surface s1-2 (same set/artist/species as owned s1-1)")
    }

    /// Recompute also fires on a wanted-only signal change (no owned), and excludes the wanted card.
    @MainActor
    func testForYouRecomputesWhenWantedChanges() async throws {
        let store = try makeStore()
        let model = DiscoverModel(store: store)

        await model.load(ownedIds: [], wantedIds: [])
        let before = model.previews[.forYou, default: []].map(\.id)

        await model.load(ownedIds: [], wantedIds: ["s1-1"])
        let after = model.previews[.forYou, default: []].map(\.id)

        XCTAssertNotEqual(before, after, "For You preview must rebuild when wanted changes")
        XCTAssertFalse(after.contains("s1-1"), "wanted card is a taste signal and is excluded")
        XCTAssertTrue(after.contains("s1-2"),
                      "recompute should surface s1-2 (sibling of wanted s1-1)")
    }

    /// For You caption resolves a species reason: after owning Pikachu (dex 25), a sibling card of
    /// the same species reads "Because you like Pikachu" rather than the artist reason.
    @MainActor
    func testForYouCaptionUsesSpeciesReason() async throws {
        let store = try makeStore()
        let model = DiscoverModel(store: store)
        await model.load(ownedIds: ["s1-1"], wantedIds: [])            // owns Pikachu (dex 25)
        let raichu = try XCTUnwrap(try store.card(id: "s1-2"))         // dex 25, rarity Rare (not full-art)
        XCTAssertEqual(model.caption(for: raichu, kind: .forYou), "Because you like Pikachu")
    }
}
