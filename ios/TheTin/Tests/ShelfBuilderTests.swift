import XCTest
import GRDB
@testable import TheTin

final class ShelfBuilderTests: XCTestCase {
    /// ⚠️ **This fixture is deliberately larger than every limit it exercises.** Shelves dedupe
    /// against each other, so seven shelves × `maxCardsPerShelf` need ~170 candidates before any
    /// assertion about a *later* shelf means anything. A 41-card fixture silently starved every
    /// shelf after the second, and four tests failed for a reason that had nothing to do with what
    /// they were testing. Same trap as Task 1's `ORDER BY`: a fixture smaller than the limit passes
    /// or fails for the wrong reason.
    ///
    /// - `s1` — the chased set: 30 cards, Artist A, in band. Feeds `setGoal`.
    /// - `s4` — 80 cards, Artist A, dex 144 or 6. Feeds both `species` shelves and `artist`.
    /// - `s5` — 80 cards, Artist D, no dex, unknown to the profile. Feeds `band` and `explore`.
    /// - `s2` — one card far above any plausible ceiling.
    private func makeStore() throws -> CatalogStore {
        let path = NSTemporaryDirectory() + "cat-shelfb-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE set_info(id TEXT PRIMARY KEY, name TEXT, release_date TEXT, total INTEGER, era TEXT, rep_card_id TEXT);
            CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT, number TEXT, name TEXT, hp INTEGER, types TEXT, rarity TEXT, artist TEXT, image_base TEXT, tcgplayer_id INTEGER);
            CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL, psa3 REAL, psa7 REAL, psa9 REAL, psa10 REAL, as_of TEXT);
            CREATE TABLE card_dex(card_id TEXT NOT NULL, dex_id INTEGER NOT NULL, PRIMARY KEY(card_id, dex_id));
            CREATE TABLE pokemon(dex_id INTEGER PRIMARY KEY, name TEXT NOT NULL, rep_card_id TEXT);
            CREATE TABLE price_history(card_id TEXT NOT NULL, date TEXT NOT NULL, raw_usd REAL NOT NULL, PRIMARY KEY(card_id, date));
            CREATE TABLE price_delta(card_id TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL,
                                     pct_1d REAL, pct_7d REAL, pct_30d REAL, PRIMARY KEY(card_id, kind, key));
            INSERT INTO set_info VALUES ('s1','Pitch Black','2026-07-17',40,'Mega','s1-1');
            INSERT INTO set_info VALUES ('s2','Grail Set','2026-01-01',1,'Mega','s2-1');
            INSERT INTO set_info VALUES ('s4','Species Set','2026-03-01',80,'Mega','s4-1');
            INSERT INTO set_info VALUES ('s5','Unknown Set','2026-02-01',80,'Mega','s5-1');
            INSERT INTO pokemon VALUES (144,'Articuno',NULL);
            INSERT INTO pokemon VALUES (6,'Charizard',NULL);
            """)
            for i in 1...30 {
                try db.execute(sql: "INSERT INTO card VALUES (?,'s1',?,?,60,'','Rare','Artist A','i',?)",
                               arguments: ["s1-\(i)", "\(i)", "Card \(i)", i])
                try db.execute(sql: "INSERT INTO price_latest VALUES (?,20.0,NULL,NULL,NULL,NULL,NULL,'2026-08-01')",
                               arguments: ["s1-\(i)"])
            }
            // Species + artist material: half dex 144, half dex 6.
            for i in 1...80 {
                try db.execute(sql: "INSERT INTO card VALUES (?,'s4',?,?,60,'','Rare','Artist A','i',?)",
                               arguments: ["s4-\(i)", "\(i)", "Species \(i)", 200 + i])
                try db.execute(sql: "INSERT INTO price_latest VALUES (?,22.0,NULL,NULL,NULL,NULL,NULL,'2026-08-01')",
                               arguments: ["s4-\(i)"])
                try db.execute(sql: "INSERT INTO card_dex VALUES (?,?)",
                               arguments: ["s4-\(i)", i <= 40 ? 144 : 6])
            }
            // A set AND artist the profile has never seen, in band — explore-shelf material.
            for i in 1...80 {
                try db.execute(sql: "INSERT INTO card VALUES (?,'s5',?,?,60,'','Rare','Artist D','i',?)",
                               arguments: ["s5-\(i)", "\(i)", "Fresh \(i)", 500 + i])
                try db.execute(sql: "INSERT INTO price_latest VALUES (?,21.0,NULL,NULL,NULL,NULL,NULL,'2026-08-01')",
                               arguments: ["s5-\(i)"])
            }
            try db.execute(sql: """
                INSERT INTO card VALUES ('s2-1','s2','1','Grail',60,'','Ultra Rare','Artist B','i',999);
                INSERT INTO price_latest VALUES ('s2-1',4500.0,NULL,NULL,NULL,NULL,NULL,'2026-08-01');
                -- s1-1 is BOTH in the chased set and a liked species: the contested-card case.
                INSERT INTO card_dex VALUES ('s1-1',144);
                """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    private let band = PriceBand(p25: 10, p50: 20, p75: 30)

    private func build(store: CatalogStore, dismissed: Set<String> = [],
                       priceCeiling: Double? = nil, tasteIds: Set<String> = [],
                       setGoals: Set<String> = ["s1"],
                       band: PriceBand? = nil,
                       profile: DiscoverAffinity.Profile = .init(sets: ["s1": 1.0],
                                                                 artists: ["Artist A": 1.0])) -> [Shelf] {
        ShelfBuilder.build(store: store, profile: profile, band: band ?? self.band, setGoals: setGoals,
                           owned: [], tasteIds: tasteIds, dismissed: dismissed,
                           priceCeiling: priceCeiling, relatedSpecies: [:])
    }

    // MARK: The seam

    /// ⚠️ THE REGRESSION THAT MATTERS. `ForYouStream.varietyPicks` drew from
    /// `topPricedCards(offset: 0, limit: 300)` and was appended AFTER the ceiling was applied to the
    /// candidate pool, so a $4,500 card sat at slot 4 of page 0 of a deck whose band was $5–$34, and
    /// each dismissal merely promoted the next grail — 300 deep. Every shelf must pass one seam.
    func testACardAboveTheCeilingAppearsInNoShelfIncludingExplore() throws {
        let shelves = build(store: try makeStore(), priceCeiling: 100)
        XCTAssertFalse(shelves.isEmpty, "the fixture must produce shelves or this asserts nothing")
        for shelf in shelves {
            XCTAssertFalse(shelf.cardIds.contains("s2-1"),
                           "\(shelf.kind.rawValue) leaked a card above the price ceiling")
        }
    }

    func testDismissedCardsAppearInNoShelf() throws {
        let shelves = build(store: try makeStore(), dismissed: ["s1-1", "s1-2"])
        XCTAssertFalse(shelves.isEmpty)
        for shelf in shelves {
            XCTAssertFalse(shelf.cardIds.contains("s1-1"), shelf.id)
            XCTAssertFalse(shelf.cardIds.contains("s1-2"), shelf.id)
        }
    }

    func testOwnedAndWantedCardsAppearInNoShelf() throws {
        let shelves = build(store: try makeStore(), tasteIds: ["s1-5"])
        for shelf in shelves {
            XCTAssertFalse(shelf.cardIds.contains("s1-5"), shelf.id)
        }
    }

    func testAdmitsRejectsAtOrAboveTheCeilingAndAllowsUnpriced() {
        XCTAssertFalse(ShelfBuilder.admits(price: 100, priceCeiling: 100))
        XCTAssertFalse(ShelfBuilder.admits(price: 101, priceCeiling: 100))
        XCTAssertTrue(ShelfBuilder.admits(price: 99, priceCeiling: 100))
        // An unpriced card is neutral, not bad — the rule `PriceBand.fit` already follows.
        XCTAssertTrue(ShelfBuilder.admits(price: nil, priceCeiling: 100))
        XCTAssertTrue(ShelfBuilder.admits(price: 5000, priceCeiling: nil))
    }

    // MARK: Caps and shape

    func testShelfCapIsEnforcedInTheBuilder() throws {
        let shelves = build(store: try makeStore())
        XCTAssertFalse(shelves.isEmpty)
        for shelf in shelves {
            XCTAssertLessThanOrEqual(shelf.cardIds.count, ShelfBuilder.maxCardsPerShelf, shelf.id)
        }
        // s1 holds 30 in-band cards against a cap of 24, so the goal shelf must be trimmed.
        let goal = try XCTUnwrap(shelves.first { $0.kind == .setGoal })
        XCTAssertEqual(goal.cardIds.count, ShelfBuilder.maxCardsPerShelf)
    }

    func testNoShelfRepeatsACardWithinItself() throws {
        for shelf in build(store: try makeStore()) {
            XCTAssertEqual(Set(shelf.cardIds).count, shelf.cardIds.count, shelf.id)
        }
    }

    /// ⚠️ `ForYouShelvesView` renders every row AT ONCE, so a card on two shelves is visible twice
    /// side by side. Measured on real data before this rule existed, "Because you like Articuno" and
    /// "More from 5ban Graphics" led with the same three cards — which reads as a rendering bug.
    /// Shelves are built in priority order, so a card lands under the strongest reason for it.
    func testNoCardAppearsOnTwoShelves() throws {
        let profile = DiscoverAffinity.Profile(sets: ["s1": 1.0], species: [144: 1.0, 6: 0.9],
                                               artists: ["Artist A": 1.0])
        let shelves = build(store: try makeStore(), profile: profile)
        XCTAssertGreaterThan(shelves.count, 2, "need several shelves for this to assert anything")
        var seen: Set<String> = []
        for shelf in shelves {
            for id in shelf.cardIds {
                XCTAssertTrue(seen.insert(id).inserted,
                              "\(id) appears on \(shelf.id) and on an earlier shelf")
            }
        }
    }

    func testTheHighestPriorityShelfKeepsAContestedCard() throws {
        let profile = DiscoverAffinity.Profile(sets: ["s1": 1.0], species: [144: 1.0],
                                               artists: ["Artist A": 1.0])
        let shelves = build(store: try makeStore(), profile: profile)
        // s1-1 carries dex 144 and is in the chased set; the set goal outranks the species shelf.
        let goal = try XCTUnwrap(shelves.first { $0.kind == .setGoal })
        let species = shelves.first { $0.kind == .species }
        if goal.cardIds.contains("s1-1") {
            XCTAssertFalse(species?.cardIds.contains("s1-1") ?? false)
        }
    }

    func testSetGoalTitleNamesTheSetAndWhatIsLeft() throws {
        let goal = try XCTUnwrap(build(store: try makeStore()).first { $0.kind == .setGoal })
        XCTAssertEqual(goal.title, "Finish Pitch Black · 30 left")
    }

    // MARK: Reason — title vs caption

    /// ⚠️ The caption is what appears under a card in the deck, and it must say why THAT CARD is in
    /// front of you. It used to come from `DiscoverAffinity.forYouReason`, which put full-art first
    /// — so a card sitting in the deck *because it completes a set you are collecting* read
    /// "✨ Full-art find". Verified on the simulator against real data: every card in the round-robin
    /// said "Full-art find", including the two set-goal cards leading it.
    func testCaptionSaysWhyTheCardIsThereNotWhatItLooksLike() {
        let goal = Shelf(id: "setGoal/me05", kind: .setGoal, subject: "Pitch Black",
                         detail: "120 left", cardIds: ["a"])
        XCTAssertEqual(goal.title, "Finish Pitch Black · 120 left")
        XCTAssertEqual(goal.caption, "Finishing Pitch Black")
    }

    /// A shelf-level fact belongs in the row header, never under a single card: how many cards are
    /// left in a set is a property of the shelf, not of the card in your hand.
    func testCaptionDropsShelfLevelDetail() {
        for kind in [Shelf.Kind.setGoal, .band, .species, .artist] {
            let shelf = Shelf(id: "x", kind: kind, subject: "Subject", detail: "99 left", cardIds: ["a"])
            XCTAssertFalse(shelf.caption.contains("99 left"), "\(kind.rawValue) leaked shelf detail")
            XCTAssertTrue(shelf.title.contains("99 left"), "\(kind.rawValue) dropped it from the header")
        }
    }

    func testEveryKindHasABothTitleAndCaption() {
        let subjects: [Shelf.Kind: String?] = [
            .setGoal: "Pitch Black", .band: "$33", .historicLow: nil,
            .weeklyDrop: nil, .species: "Articuno", .artist: "5ban Graphics", .explore: nil,
        ]
        let expected: [Shelf.Kind: (String, String)] = [
            .setGoal:     ("Finish Pitch Black", "Finishing Pitch Black"),
            .band:        ("Under $33 · your usual range", "In your usual range"),
            .historicLow: ("Cheapest in 6 months", "Cheapest in 6 months"),
            .weeklyDrop:  ("Down this week", "Down this week"),
            .species:     ("Because you like Articuno", "Because you like Articuno"),
            .artist:      ("More from 5ban Graphics", "More from 5ban Graphics"),
            .explore:     ("Something new", "Something new"),
        ]
        for (kind, (title, caption)) in expected {
            let shelf = Shelf(id: "x", kind: kind, subject: subjects[kind] ?? nil,
                              detail: nil, cardIds: ["a"])
            XCTAssertEqual(shelf.title, title, kind.rawValue)
            XCTAssertEqual(shelf.caption, caption, kind.rawValue)
        }
    }

    /// A missing subject must not produce "Because you like " with a dangling space.
    func testAMissingSubjectStillReadsAsASentence() {
        for kind in Shelf.Kind.allCases {
            let shelf = Shelf(id: "x", kind: kind, subject: nil, detail: nil, cardIds: ["a"])
            XCTAssertFalse(shelf.caption.hasSuffix(" "), kind.rawValue)
            XCTAssertFalse(shelf.title.hasSuffix(" "), kind.rawValue)
            XCTAssertFalse(shelf.caption.isEmpty, kind.rawValue)
        }
    }

    func testTheBuilderGivesEachShelfTheSubjectItsCaptionNeeds() throws {
        let profile = DiscoverAffinity.Profile(sets: ["s1": 1.0], species: [144: 1.0],
                                               artists: ["Artist A": 1.0])
        let shelves = build(store: try makeStore(), profile: profile)
        XCTAssertEqual(shelves.first { $0.kind == .setGoal }?.caption, "Finishing Pitch Black")
        XCTAssertEqual(shelves.first { $0.kind == .species }?.caption, "Because you like Articuno")
        XCTAssertEqual(shelves.first { $0.kind == .artist }?.caption, "More from Artist A")
        XCTAssertEqual(shelves.first { $0.kind == .band }?.caption, "In your usual range")
    }

    func testShelvesWithNoDataAreAbsentNotEmpty() throws {
        let shelves = build(store: try makeStore())
        XCTAssertTrue(shelves.allSatisfy { !$0.cardIds.isEmpty })
        // price_history and price_delta are empty here, exactly like the casual tier / simulator.
        XCTAssertNil(shelves.first { $0.kind == .historicLow })
        XCTAssertNil(shelves.first { $0.kind == .weeklyDrop })
    }

    func testShelfOrderPutsTheMostExplicitSignalFirst() throws {
        let kinds = build(store: try makeStore()).map(\.kind)
        let goal = try XCTUnwrap(kinds.firstIndex(of: .setGoal))
        let bandIndex = try XCTUnwrap(kinds.firstIndex(of: .band))
        let explore = try XCTUnwrap(kinds.firstIndex(of: .explore))
        XCTAssertLessThan(goal, bandIndex, "a set the user named outranks an inferred band")
        XCTAssertLessThan(bandIndex, explore, "a buy signal outranks exploration")
    }

    /// Novelty must come from the DIMENSION, never from the price — that is precisely what
    /// `varietyPicks` got wrong when it made "something new" mean "the most expensive card we have".
    func testExploreHoldsUnseenSetsAndArtistsButStaysInBand() throws {
        let explore = try XCTUnwrap(build(store: try makeStore()).first { $0.kind == .explore })
        XCTAssertFalse(explore.cardIds.isEmpty)
        XCTAssertTrue(explore.cardIds.allSatisfy { $0.hasPrefix("s5-") },
                      "s1/s4 are known (set or artist) and s2 is out of band; only s5 is genuinely new AND affordable")
    }

    func testNoBandMeansNoBandBackedShelvesButGoalsStillRender() throws {
        let shelves = ShelfBuilder.build(store: try makeStore(),
                                         profile: .init(sets: ["s1": 1.0]), band: nil,
                                         setGoals: ["s1"], owned: [], tasteIds: [],
                                         dismissed: [], priceCeiling: nil, relatedSpecies: [:])
        XCTAssertNotNil(shelves.first { $0.kind == .setGoal })
        XCTAssertNil(shelves.first { $0.kind == .band })
        XCTAssertNil(shelves.first { $0.kind == .explore })
    }

    func testAnEmptyProfileWithNoGoalsProducesNoShelves() throws {
        let shelves = ShelfBuilder.build(store: try makeStore(), profile: .init(), band: nil,
                                         setGoals: [], owned: [], tasteIds: [], dismissed: [],
                                         priceCeiling: nil, relatedSpecies: [:])
        XCTAssertTrue(shelves.isEmpty, "cold start renders no For You row at all — it does not guess")
    }

    // MARK: Species family dedup

    /// ⚠️ Measured on the real collection: the top three species by weight were Articuno (144),
    /// Zapdos (145) and Moltres (146). Their ±2 family windows overlap, so the three shelves shared
    /// 62–88% of their cards — three rows showing the same six cards, side by side. Card-level dedup
    /// in the round-robin cannot fix that; the shelves screen renders them simultaneously.
    func testAdjacentSpeciesCollapseToOneShelf() {
        let species: [Int: Double] = [144: 1.0, 145: 0.83, 146: 0.83, 6: 0.67, 94: 0.5]
        XCTAssertEqual(ShelfBuilder.speciesSeeds(species, limit: 4), [144, 6, 94],
                       "145 and 146 fall inside 144's window and must not seed their own shelves")
    }

    func testSpeciesSeedsPrefersTheStrongestOfAnOverlappingGroup() {
        XCTAssertEqual(ShelfBuilder.speciesSeeds([145: 0.4, 144: 0.9], limit: 4), [144])
    }

    func testSpeciesSeedsRespectsItsLimit() {
        XCTAssertEqual(ShelfBuilder.speciesSeeds([1: 1.0, 10: 0.9, 20: 0.8, 30: 0.7, 40: 0.6],
                                                 limit: 3).count, 3)
    }

    func testSpeciesSeedsIsEmptyForAnEmptyProfile() {
        XCTAssertTrue(ShelfBuilder.speciesSeeds([:], limit: 4).isEmpty)
    }

    func testSpeciesSeedsAreDeterministicForTiedWeights() {
        let tied: [Int: Double] = [50: 0.5, 10: 0.5, 30: 0.5]
        XCTAssertEqual(ShelfBuilder.speciesSeeds(tied, limit: 3),
                       ShelfBuilder.speciesSeeds(tied, limit: 3))
        XCTAssertEqual(ShelfBuilder.speciesSeeds(tied, limit: 3), [10, 30, 50])
    }

    func testASpeciesShelfIsTitledForItsSeed() throws {
        let profile = DiscoverAffinity.Profile(sets: ["s1": 1.0], species: [144: 1.0])
        let shelves = build(store: try makeStore(), profile: profile)
        let species = try XCTUnwrap(shelves.first { $0.kind == .species })
        XCTAssertEqual(species.title, "Because you like Articuno")
    }
}
