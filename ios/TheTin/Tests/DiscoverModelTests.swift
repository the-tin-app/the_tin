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
            CREATE TABLE price_history(card_id TEXT NOT NULL, date TEXT NOT NULL, raw_usd REAL NOT NULL, PRIMARY KEY(card_id, date));
            CREATE TABLE price_delta(card_id TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL,
                                     pct_1d REAL, pct_7d REAL, pct_30d REAL, PRIMARY KEY(card_id, kind, key));
            INSERT INTO set_info VALUES ('s1','Set One','2020-01-01',3,'E1','s1-2');
            INSERT INTO set_info VALUES ('s2','Set Two','2024-01-01',1,'E2','s2-1');
            INSERT INTO card VALUES ('s1-1','s1','1','Pikachu',60,'Lightning','Rare','K','img/s1-1',1);
            -- Ultra Rare on purpose: it is in `DiscoverConstants.fullArtRarities`, so this is the card
            -- the old caption path would have labelled "✨ Full-art find" regardless of why it was chosen.
            INSERT INTO card VALUES ('s1-2','s1','2','Raichu',120,'Lightning','Ultra Rare','K','img/s1-2',2);
            INSERT INTO card VALUES ('s1-3','s1','3','Eevee',50,'Colorless','Common','A','img/s1-3',3);
            INSERT INTO card VALUES ('s2-1','s2','1','Mew',60,'Psychic','Rare','A','img/s2-1',4);
            INSERT INTO price_latest VALUES ('s1-1',20.0,4.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-2',22.0,40.0,NULL,NULL,NULL,NULL,'2026-07-06');
            INSERT INTO price_latest VALUES ('s1-3',18.0,NULL,NULL,NULL,NULL,NULL,'2026-07-06');
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

    /// Three purchases are the minimum for a band (`PriceBand.minimumSamples`), and without a band
    /// only the set-goal shelf can render.
    private func entry(_ cardId: String, paid: Double) -> CollectionEntry {
        CollectionEntry(id: UUID().uuidString, cardId: cardId, groupId: "", qty: 1,
                        condition: nil, grade: nil, pricePaid: paid, acquiredAt: Date(),
                        acquiredFrom: nil, addedAt: Date())
    }

    private func inputs(owned: [(String, Double)] = [], wants: [String] = [],
                        goals: Set<String> = [], dismissed: Set<String> = [],
                        reasons: [String: DismissReason] = [:], revision: Int = 0)
        -> DiscoverModel.Inputs {
        .init(entries: owned.map { entry($0.0, paid: $0.1) },
              wants: Dictionary(uniqueKeysWithValues: wants.map { ($0, WantEntry(addedAt: Date())) }),
              setGoals: goals, dismissed: dismissed, reasons: reasons, signalsRevision: revision)
    }

    /// ⚠️ Cold start renders NO For You row — it does not guess.
    ///
    /// This test used to assert the opposite ("cold-start For You preview should carry the popular
    /// mix"). That popular mix was `topPricedCards`, so a brand-new user's first impression of a
    /// feature about what they would actually buy was a wall of $3,000–$4,500 grails. The row is
    /// absent instead, the way the Supporters row is — and the first-run picker seeds a real signal.
    @MainActor
    func testColdStartHasNoForYouButStillHasConnections() async throws {
        let model = DiscoverModel(store: try makeStore())
        await model.load(inputs())

        XCTAssertTrue(model.isLoaded)
        XCTAssertTrue(model.shelves.isEmpty, "no collection, no wishlist and no goals means no reason")
        XCTAssertTrue(model.previews[.forYou, default: []].isEmpty)
        // The rest of the home is unaffected: the curated art scene still surfaces.
        XCTAssertTrue(model.connections.contains { $0.id == "scene-a" && $0.kind == .combinedArt })
        XCTAssertFalse(model.previews[.chase, default: []].isEmpty, "Chase is its own row and is unaffected")
    }

    @MainActor
    func testOwningCardsBuildsShelvesThatExcludeWhatYouOwn() async throws {
        let model = DiscoverModel(store: try makeStore())
        await model.load(inputs(owned: [("s1-1", 20), ("s1-3", 18), ("s2-1", 30)]))

        XCTAssertFalse(model.shelves.isEmpty, "three priced purchases give a band, so shelves render")
        XCTAssertNotNil(model.band)
        let all = Set(model.shelves.flatMap(\.cardIds))
        XCTAssertFalse(all.contains("s1-1"), "an owned card is not a recommendation")
        XCTAssertTrue(all.contains("s1-2"), "s1-2 shares set, artist and species with owned s1-1")
    }

    @MainActor
    func testASetGoalRendersItsShelfEvenWithNoBand() async throws {
        let model = DiscoverModel(store: try makeStore())
        await model.load(inputs(goals: ["s1"]))

        let goal = try XCTUnwrap(model.shelves.first { $0.kind == .setGoal })
        XCTAssertEqual(goal.title, "Finish Set One · 3 left")
        XCTAssertNil(model.band, "no purchases means no band")
        XCTAssertNil(model.shelves.first { $0.kind == .easyAdds })
    }

    /// ⚠️ The recompute trigger this replaces could not see a dismissal at all. `lastSignal` was
    /// `(owned.count, wanted.count)`, and thumbing a card down changes neither — so the deck kept
    /// showing the rejected card until the user happened to add or heart something, and the gesture
    /// read as doing nothing.
    @MainActor
    func testADismissalAloneTriggersARebuild() async throws {
        let model = DiscoverModel(store: try makeStore())
        let owned = [("s1-1", 20.0), ("s1-3", 18.0), ("s2-1", 30.0)]
        await model.load(inputs(owned: owned))
        XCTAssertTrue(model.shelves.flatMap(\.cardIds).contains("s1-2"))

        await model.load(inputs(owned: owned, dismissed: ["s1-2"], revision: 1))
        XCTAssertFalse(model.shelves.flatMap(\.cardIds).contains("s1-2"),
                       "a thumbs-down must reach the shelves without any other change")
    }

    @MainActor
    func testIdenticalInputsDoNotRebuild() async throws {
        let model = DiscoverModel(store: try makeStore())
        let same = inputs(owned: [("s1-1", 20), ("s1-3", 18), ("s2-1", 30)])
        await model.load(same)
        let first = model.shelves.map(\.id)
        await model.load(same)
        XCTAssertEqual(model.shelves.map(\.id), first)
    }

    /// ⚠️ **This is the test that should have existed two bugs ago.**
    ///
    /// `DiscoverView.task(id:)` used a hand-written key that counted owned and wanted cards. Twice,
    /// a change it did not enumerate failed to trigger a rebuild and the surface silently kept a
    /// stale assembly: a thumbs-down never reached the deck, and answering the first-run picker left
    /// the three price-tier rows missing until the app was relaunched — found on device, on first
    /// run. Adding one more term each time is how it recurs.
    ///
    /// Every input must move the key. A new field that forgets to appear fails here rather than on
    /// someone's first launch.
    func testEveryInputChangesTheRecomputeKey() {
        let base = inputs(owned: [("s1-1", 20)], wants: ["s1-2"], goals: ["s1"],
                          dismissed: ["s1-3"], reasons: ["s1-3": .notMySpecies], revision: 1)
        var withTiers = base
        withTiers.tiers = PriceTiers(routineCeiling: 10, occasionalCeiling: 60)

        var variants: [String: DiscoverModel.Inputs] = [:]
        variants["entries"] = { var i = base; i.entries = []; return i }()
        variants["pricePaid"] = { var i = base; i.entries[0].pricePaid = 99; return i }()
        variants["wants"] = { var i = base; i.wants = [:]; return i }()
        variants["priority"] = {
            var i = base; i.wants["s1-2"]?.priority = .grail; return i
        }()
        variants["setGoals"] = { var i = base; i.setGoals = ["s2"]; return i }()
        variants["dismissed"] = { var i = base; i.dismissed = []; return i }()
        variants["reasons"] = { var i = base; i.reasons = ["s1-3": .wrongEra]; return i }()
        variants["revision"] = { var i = base; i.signalsRevision = 2; return i }()
        variants["tiers"] = withTiers
        variants["tiers changed"] = {
            var i = withTiers
            i.tiers = PriceTiers(routineCeiling: 25, occasionalCeiling: 60)
            return i
        }()

        for (name, variant) in variants {
            XCTAssertNotEqual(variant.recomputeKey, name == "tiers changed" ? withTiers.recomputeKey
                                                                           : base.recomputeKey,
                              "changing \(name) must trigger a rebuild")
        }
    }

    func testTheSameInputsProduceTheSameKey() {
        let a = inputs(owned: [("s1-1", 20)], wants: ["s1-2"], goals: ["s1"])
        let b = inputs(owned: [("s1-1", 20)], wants: ["s1-2"], goals: ["s1"])
        XCTAssertEqual(a.recomputeKey, b.recomputeKey, "a stable input must not churn the surface")
    }

    /// The device bug, at model level: stating your price tiers must produce the tier rows without
    /// anything else changing.
    @MainActor
    func testStatingTiersAloneProducesTheTierRows() async throws {
        let model = DiscoverModel(store: try makeStore())
        var noTiers = inputs(owned: [("s1-1", 20), ("s1-3", 18), ("s2-1", 30)])
        await model.load(noTiers)
        XCTAssertNil(model.shelves.first { $0.kind == .easyAdds })

        noTiers.tiers = PriceTiers(routineCeiling: 25, occasionalCeiling: 100)
        await model.load(noTiers)
        XCTAssertNotNil(model.shelves.first { $0.kind == .easyAdds },
                        "answering the picker must build the tier rows immediately")
    }

    /// ⚠️ The caption must name the reason the card was CHOSEN, not describe the card.
    ///
    /// This is the bug I watched on the simulator against real data: every card in the round-robin
    /// read "✨ Full-art find", including the two set-goal cards leading it. `forYouReason` ranked
    /// full-art above every other explanation and had no idea why the card had been picked, so a
    /// card sitting in the deck because it completes a set you are chasing was described by its
    /// finish. Here `s1-2` is an Ultra Rare — full-art by `DiscoverConstants.fullArtRarities` — in a
    /// set the user is collecting, which is exactly the case that used to lie.
    @MainActor
    func testCaptionNamesTheShelfNotTheCardsFinish() async throws {
        let store = try makeStore()
        let model = DiscoverModel(store: store)
        await model.load(inputs(goals: ["s1"]))

        let raichu = try XCTUnwrap(try store.card(id: "s1-2"))
        XCTAssertEqual(raichu.rarity, "Ultra Rare")
        XCTAssertTrue(DiscoverConstants.fullArtRarities.contains("Ultra Rare"),
                      "precondition: this is the rarity the old caption would have led with")
        XCTAssertEqual(model.caption(for: raichu, kind: .forYou), "Finishing Set One")
    }

    @MainActor
    func testCaptionUsesTheSpeciesShelfWhenThatIsWhyTheCardIsThere() async throws {
        let store = try makeStore()
        let model = DiscoverModel(store: store)
        await model.load(inputs(owned: [("s1-1", 20), ("s1-3", 18), ("s2-1", 30)]))
        let raichu = try XCTUnwrap(try store.card(id: "s1-2"))
        let caption = try XCTUnwrap(model.caption(for: raichu, kind: .forYou))
        XCTAssertFalse(caption.contains("Full-art"), "captions explain, they do not describe")
    }

    /// A card no shelf placed has no reason to give, and the caption line collapses rather than
    /// inventing one.
    @MainActor
    func testAnUnplacedCardHasNoCaption() async throws {
        let store = try makeStore()
        let model = DiscoverModel(store: store)
        await model.load(inputs(owned: [("s1-1", 20), ("s1-3", 18), ("s2-1", 30)]))
        let owned = try XCTUnwrap(try store.card(id: "s1-1"))
        XCTAssertNil(model.caption(for: owned, kind: .forYou))
    }
}
