import XCTest
@testable import TheTin

final class DiscoverSimilarityTests: XCTestCase {

    func testExactSeedsKeepTheirFullWeight() {
        let out = DiscoverAffinity.relatedSpecies(seed: [25: 1.0], coOccurring: [])
        XCTAssertEqual(out[25] ?? 0, 1.0, accuracy: 0.001)
    }

    func testAdjacentDexIdsAreIncludedAtAReducedWeight() {
        // Charmander 4 → Charmeleon 5, Charizard 6. Evolution families are contiguous dex ids,
        // so +-2 covers a full three-stage family from either end.
        let out = DiscoverAffinity.relatedSpecies(seed: [4: 1.0], coOccurring: [])
        XCTAssertEqual(out[5] ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(out[6] ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(out[2] ?? 0, 0.6, accuracy: 0.001)
    }

    func testAdjacencyStopsAtTheRadius() {
        let out = DiscoverAffinity.relatedSpecies(seed: [4: 1.0], coOccurring: [])
        XCTAssertNil(out[7])
        XCTAssertNil(out[1])
    }

    func testAdjacencyNeverProducesANonPositiveDexId() {
        // Bulbasaur is dex 1; 1-2 = -1 is not a species.
        let out = DiscoverAffinity.relatedSpecies(seed: [1: 1.0], coOccurring: [])
        XCTAssertNil(out[0])
        XCTAssertNil(out[-1])
    }

    func testAdjacencyScalesWithTheSeedWeight() {
        // A half-strength seed produces half-strength neighbours — a species you barely like
        // must not promote its whole family as hard as one you love.
        let out = DiscoverAffinity.relatedSpecies(seed: [4: 0.5], coOccurring: [])
        XCTAssertEqual(out[5] ?? 0, 0.3, accuracy: 0.001)
    }

    func testCoOccurringSpeciesAreIncluded() {
        let out = DiscoverAffinity.relatedSpecies(seed: [25: 1.0], coOccurring: [644])
        XCTAssertEqual(out[644] ?? 0, 0.5, accuracy: 0.001)
    }

    func testAnExactSeedIsNeverDowngradedByAWeakerSource() {
        // 26 is both an exact seed and adjacent to 25. It must keep 1.0, not drop to 0.6.
        let out = DiscoverAffinity.relatedSpecies(seed: [25: 1.0, 26: 1.0], coOccurring: [26])
        XCTAssertEqual(out[26] ?? 0, 1.0, accuracy: 0.001)
    }

    func testTheStrongestSourceWinsBetweenTwoDerivedRoutes() {
        // 26 is adjacent to 25 (0.6) and co-occurring (0.5) — it takes the higher.
        let out = DiscoverAffinity.relatedSpecies(seed: [25: 1.0], coOccurring: [26])
        XCTAssertEqual(out[26] ?? 0, 0.6, accuracy: 0.001)
    }

    func testAnEmptySeedProducesNothing() {
        XCTAssertTrue(DiscoverAffinity.relatedSpecies(seed: [:], coOccurring: [644]).isEmpty)
    }

    // MARK: derived species must survive the bucket cut

    /// ⚠️ Regression, found on real data 2026-08-04. Adjacency caps at 0.6x its seed, so with five
    /// exact species at >= 0.6 the top-4 bucket cut was ALL exact matches and no derived species
    /// reached page 0 — the first one landed at rank 6. The expansion worked and was invisible.
    func testDerivedSpeciesGetBucketSlotsEvenWhenExactMatchesFillTheCut() {
        // Five exact species all at full weight — every one outranks any 0.6 adjacency entry.
        let exact: [Int: Double] = [1: 1.0, 20: 1.0, 40: 0.8, 60: 0.8, 80: 0.6]
        let related = DiscoverAffinity.relatedSpecies(seed: exact, coOccurring: [])
        let buckets = DiscoverAffinity.speciesBuckets(exact: exact, related: related, depth: 4)
        let derived = buckets.filter { exact[$0] == nil }
        XCTAssertFalse(derived.isEmpty, "the widened map is pointless if it never reaches the pool")
    }

    func testExactSpeciesStillLeadTheBuckets() {
        let exact: [Int: Double] = [1: 1.0, 20: 1.0, 40: 0.8, 60: 0.8, 80: 0.6]
        let related = DiscoverAffinity.relatedSpecies(seed: exact, coOccurring: [])
        let buckets = DiscoverAffinity.speciesBuckets(exact: exact, related: related, depth: 4)
        XCTAssertEqual(Array(buckets.prefix(2)).sorted(), [1, 20], "strongest exact matches come first")
    }

    func testNoExactSpeciesYieldsNoBuckets() {
        XCTAssertTrue(DiscoverAffinity.speciesBuckets(exact: [:], related: [:], depth: 4).isEmpty)
    }

    // MARK: species outranks set/artist

    /// ⚠️ Found on real data 2026-08-04. `score` summed five dimensions flat, so set + artist +
    /// rarity + type could contribute ~4 points against species' maximum of 1 — "similar Pokemon"
    /// structurally could not beat "same set, same artist". Species is the dimension the user
    /// actually asked to browse by, so it is weighted above the rest.
    func testASpeciesMatchBeatsASetAndArtistMatch() {
        var profile = DiscoverAffinity.Profile()
        profile.sets = ["A": 1.0]
        profile.artists = ["K": 1.0]
        profile.species = [25: 1.0]
        let setAndArtist = card("set-artist", set: "A", artist: "K")   // 1.0 + 1.0 = 2.0
        let speciesOnly = card("species", set: "Z", artist: "Z")       // species only
        let ranked = DiscoverAffinity.rank(
            candidates: [setAndArtist, speciesOnly],
            dexIds: ["species": [25]], profile: profile)
        XCTAssertEqual(ranked.first?.id, "species",
                       "a liked species must outrank a liked set + liked artist")
    }

    // MARK: generation affinity

    func testGenerationsAreRolledUpFromDexIds() {
        let owned = [card("g1", set: "A"), card("g8", set: "B")]
        let p = DiscoverAffinity.profile(owned: owned, wanted: [], dexIds: ["g1": [25], "g8": [880]])
        XCTAssertEqual(p.generations[1] ?? 0, 1.0, accuracy: 0.001)   // dex 25 -> Gen 1
        XCTAssertEqual(p.generations[8] ?? 0, 1.0, accuracy: 0.001)   // dex 880 -> Gen 8
        XCTAssertNil(p.generations[4])                                 // never touched
    }

    func testACardFromAGenerationYouNeverTouchIsHeavilyDemoted() {
        // 121 of this user's 127 dex hits are Gens 1-5; Gen 8 is zero. A Gen 8 card must not
        // rank alongside a Gen 1 card just because it shares a liked artist.
        var p = DiscoverAffinity.Profile()
        p.generations = [1: 1.0]
        XCTAssertEqual(DiscoverAffinity.generationFit([25], profile: p), 1.0, accuracy: 0.001)
        XCTAssertEqual(DiscoverAffinity.generationFit([880], profile: p),
                       DiscoverAffinity.dimensionFloor, accuracy: 0.001)
    }

    func testAnEmptyGenerationProfileIsNeutral() {
        // Cold start must not demote the entire catalog to the floor.
        XCTAssertEqual(DiscoverAffinity.generationFit([25], profile: DiscoverAffinity.Profile()),
                       1.0, accuracy: 0.001)
    }

    func testACardWithNoSpeciesIsNeutralOnGeneration() {
        // Trainers and energy have no dex id — they must not be punished for it.
        var p = DiscoverAffinity.Profile()
        p.generations = [1: 1.0]
        XCTAssertEqual(DiscoverAffinity.generationFit([], profile: p), 1.0, accuracy: 0.001)
    }

    func testTheBestGenerationOnAMultiSpeciesCardWins() {
        var p = DiscoverAffinity.Profile()
        p.generations = [1: 1.0]
        XCTAssertEqual(DiscoverAffinity.generationFit([880, 25], profile: p), 1.0, accuracy: 0.001)
    }

    // MARK: rarity as a filter, not just an attractor

    func testACommonIsDemotedWhenYouOnlyCollectFullArt() {
        // 85 of 121 of this user's cards are full-art tier; exactly one is Common.
        var p = DiscoverAffinity.Profile()
        p.rarities = ["Illustration rare": 1.0, "Common": 0.03]
        let fullArt = DiscoverAffinity.rarityFit("Illustration rare", profile: p)
        let common = DiscoverAffinity.rarityFit("Common", profile: p)
        XCTAssertEqual(fullArt, 1.0, accuracy: 0.001)
        XCTAssertLessThan(common, 0.25)
    }

    func testAnUnseenRarityFallsToTheFloorRatherThanZero() {
        var p = DiscoverAffinity.Profile()
        p.rarities = ["Illustration rare": 1.0]
        XCTAssertEqual(DiscoverAffinity.rarityFit("Common", profile: p),
                       DiscoverAffinity.dimensionFloor, accuracy: 0.001)
    }

    func testAnEmptyRarityProfileIsNeutral() {
        XCTAssertEqual(DiscoverAffinity.rarityFit("Common", profile: DiscoverAffinity.Profile()),
                       1.0, accuracy: 0.001)
    }

    /// The whole point, end to end: a Common from an untouched generation must lose to an in-band
    /// full-art card of a liked generation, **even though both match the species**.
    func testAFullArtCardOfALikedGenerationBeatsACommonFromAnUntouchedOne() {
        var p = DiscoverAffinity.Profile()
        p.species = [25: 1.0]
        p.rarities = ["Illustration rare": 1.0]
        p.generations = [1: 1.0]
        let good = CardRecord(id: "good", setId: "Z", number: "1", name: "good", hp: nil, types: [],
                              rarity: "Illustration rare", artist: nil, imageBase: nil,
                              imageUrl: nil, tcgplayerId: nil)
        let bad = CardRecord(id: "bad", setId: "Z", number: "2", name: "bad", hp: nil, types: [],
                             rarity: "Common", artist: nil, imageBase: nil,
                             imageUrl: nil, tcgplayerId: nil)
        let ranked = DiscoverAffinity.rank(candidates: [bad, good],
                                           dexIds: ["good": [25], "bad": [880]], profile: p)
        XCTAssertEqual(ranked.first?.id, "good")
    }

    // MARK: band fit and twins in the ranker

    private func card(_ id: String, set: String, artist: String? = nil) -> CardRecord {
        CardRecord(id: id, setId: set, number: "1", name: id, hp: nil, types: [],
                   rarity: nil, artist: artist, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }

    func testBandFitReordersTwoOtherwiseEqualCards() {
        let owned = [card("o1", set: "A")]
        let profile = DiscoverAffinity.profile(owned: owned, wanted: [], dexIds: [:])
        let band = PriceBand(p25: 10, p50: 15, p75: 20)
        let candidates = [card("expensive", set: "A"), card("in-band", set: "A")]
        let ranked = DiscoverAffinity.rank(
            candidates: candidates, dexIds: [:], profile: profile, band: band,
            prices: ["expensive": 500, "in-band": 15])
        XCTAssertEqual(ranked.map(\.id), ["in-band", "expensive"])
    }

    func testAnOutOfBandCardIsDemotedButNeverDropped() {
        // The 0.35 floor exists so a grail stays visible. It must still be in the result.
        let owned = [card("o1", set: "A")]
        let profile = DiscoverAffinity.profile(owned: owned, wanted: [], dexIds: [:])
        let band = PriceBand(p25: 10, p50: 15, p75: 20)
        let ranked = DiscoverAffinity.rank(
            candidates: [card("grail", set: "A")], dexIds: [:], profile: profile, band: band,
            prices: ["grail": 100_000])
        XCTAssertEqual(ranked.map(\.id), ["grail"])
    }

    func testAnUnpricedCardIsNotPenalisedByTheBand() {
        let owned = [card("o1", set: "A")]
        let profile = DiscoverAffinity.profile(owned: owned, wanted: [], dexIds: [:])
        let band = PriceBand(p25: 10, p50: 15, p75: 20)
        let ranked = DiscoverAffinity.rank(
            candidates: [card("unpriced", set: "A"), card("far-out", set: "A")],
            dexIds: [:], profile: profile, band: band, prices: ["far-out": 100_000])
        XCTAssertEqual(ranked.first?.id, "unpriced")
    }

    func testATwinOfAWantedCardOutranksAPlainMatch() {
        let owned = [card("o1", set: "A")]
        let profile = DiscoverAffinity.profile(owned: owned, wanted: [], dexIds: [:])
        let ranked = DiscoverAffinity.rank(
            candidates: [card("plain", set: "A"), card("twin", set: "A")],
            dexIds: [:], profile: profile, twinIds: ["twin"])
        XCTAssertEqual(ranked.map(\.id), ["twin", "plain"])
    }

    func testRankWithNoBandAndNoTwinsIsUnchanged() {
        // The defaults must be a no-op, or every existing call site silently changes behaviour.
        let owned = [card("o1", set: "A", artist: "K")]
        let profile = DiscoverAffinity.profile(owned: owned, wanted: [], dexIds: [:])
        let candidates = [card("c2", set: "A", artist: "K"), card("c1", set: "A", artist: "Z")]
        XCTAssertEqual(DiscoverAffinity.rank(candidates: candidates, dexIds: [:], profile: profile).map(\.id),
                       ["c2", "c1"])
    }
}

/// `DiscoverModel.keepingRejectedInPlace` — a rejected card must hold its slot so the thumbs-down
/// is visibly captured, instead of the tile vanishing from under the finger.
final class DiscoverRejectedSlotTests: XCTestCase {
    private func card(_ id: String) -> CardRecord {
        CardRecord(id: id, setId: "S", number: "1", name: id, hp: nil, types: [],
                   rarity: nil, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }

    func testARejectedCardHoldsItsPosition() {
        let old: [DiscoverModel.StreamKind: [CardRecord]] = [.forYou: [card("a"), card("b"), card("c")]]
        let new: [DiscoverModel.StreamKind: [CardRecord]] = [.forYou: [card("a"), card("c"), card("d")]]
        let out = DiscoverModel.keepingRejectedInPlace(new: new, old: old, dismissed: ["b"])
        XCTAssertEqual(out[.forYou]?.map(\.id), ["a", "b", "c"])
    }

    func testTheRowDoesNotGrow() {
        let old: [DiscoverModel.StreamKind: [CardRecord]] = [.forYou: [card("a"), card("b")]]
        let new: [DiscoverModel.StreamKind: [CardRecord]] = [.forYou: [card("a"), card("c")]]
        let out = DiscoverModel.keepingRejectedInPlace(new: new, old: old, dismissed: ["b"])
        XCTAssertEqual(out[.forYou]?.count, 2)
    }

    /// A rejected card must never be resurrected somewhere it was not already showing — otherwise
    /// dismissing a card could make it APPEAR on a row it had never been on.
    func testARejectedCardNotPreviouslyOnScreenIsNotInserted() {
        let old: [DiscoverModel.StreamKind: [CardRecord]] = [.forYou: [card("a")]]
        let new: [DiscoverModel.StreamKind: [CardRecord]] = [.forYou: [card("a")]]
        let out = DiscoverModel.keepingRejectedInPlace(new: new, old: old, dismissed: ["zzz"])
        XCTAssertEqual(out[.forYou]?.map(\.id), ["a"])
    }

    func testNoDismissalsIsAnExactPassThrough() {
        let new: [DiscoverModel.StreamKind: [CardRecord]] = [.forYou: [card("a"), card("b")]]
        let out = DiscoverModel.keepingRejectedInPlace(new: new, old: [.forYou: [card("a")]], dismissed: [])
        XCTAssertEqual(out[.forYou]?.map(\.id), ["a", "b"])
    }

    func testAnEmptyNewRowIsLeftAlone() {
        // Nothing to pin a slot against, and re-inserting would resurrect a dead row.
        let out = DiscoverModel.keepingRejectedInPlace(new: [.forYou: []],
                                                       old: [.forYou: [card("a")]], dismissed: ["a"])
        XCTAssertEqual(out[.forYou]?.count, 0)
    }

    func testACardStillPresentInTheNewRowIsNotDuplicated() {
        let old: [DiscoverModel.StreamKind: [CardRecord]] = [.forYou: [card("a"), card("b")]]
        let new: [DiscoverModel.StreamKind: [CardRecord]] = [.forYou: [card("a"), card("b")]]
        let out = DiscoverModel.keepingRejectedInPlace(new: new, old: old, dismissed: ["b"])
        XCTAssertEqual(out[.forYou]?.map(\.id), ["a", "b"])
    }
}
