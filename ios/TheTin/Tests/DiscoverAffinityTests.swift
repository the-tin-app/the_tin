import XCTest
@testable import TheTin

final class DiscoverAffinityTests: XCTestCase {
    private func card(_ id: String, set: String, artist: String? = nil,
                      rarity: String? = nil, types: [String] = []) -> CardRecord {
        CardRecord(id: id, setId: set, number: "1", name: id, hp: nil, types: types,
                   rarity: rarity, artist: artist, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }

    func testEmptyProfileWhenNoSignal() {
        let p = DiscoverAffinity.profile(owned: [], wanted: [], dexIds: [:])
        XCTAssertTrue(p.isEmpty)
    }

    func testWantedWeightedHigherThanOwnedAndNormalized() {
        // owned: setA x1 (weight 1). wanted: setB x1 (weight 2). Normalized by max (2) → A=0.5, B=1.0.
        let owned = [card("o1", set: "A")]
        let wanted = [card("w1", set: "B")]
        let p = DiscoverAffinity.profile(owned: owned, wanted: wanted, dexIds: [:])
        XCTAssertEqual(p.sets["A"] ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(p.sets["B"] ?? 0, 1.0, accuracy: 0.001)
    }

    func testSpeciesAccumulatedFromDexIds() {
        let owned = [card("o1", set: "A")]
        let p = DiscoverAffinity.profile(owned: owned, wanted: [], dexIds: ["o1": [25]])
        XCTAssertEqual(p.species[25] ?? 0, 1.0, accuracy: 0.001) // only value → normalizes to 1
    }

    func testRankOrdersByScoreDescAndDropsZero() {
        // profile favors set A (1.0) and artist "K" (1.0)
        let owned = [card("o1", set: "A", artist: "K")]
        let p = DiscoverAffinity.profile(owned: owned, wanted: [], dexIds: [:])
        let candidates = [
            card("c-match2", set: "A", artist: "K"), // score ~2 (set + artist)
            card("c-match1", set: "A", artist: "Z"), // score ~1 (set only)
            card("c-zero",  set: "Q", artist: "Z"),  // score 0 → dropped
        ]
        let ranked = DiscoverAffinity.rank(candidates: candidates, dexIds: [:], profile: p)
        XCTAssertEqual(ranked.map(\.id), ["c-match2", "c-match1"])
    }

    func testDiversityCapPerSet() {
        let owned = [card("o1", set: "A")]
        let p = DiscoverAffinity.profile(owned: owned, wanted: [], dexIds: [:])
        let candidates = (1...5).map { card("c\($0)", set: "A") } // all set A, all score 1
        let ranked = DiscoverAffinity.rank(candidates: candidates, dexIds: [:], profile: p, perGroupCap: 3, limit: 30)
        XCTAssertEqual(ranked.count, 3) // capped at 3 per set
    }

    func testLimit() {
        // 10 distinct sets, each with equal weight → every candidate scores > 0 and the
        // per-set cap never binds; limit should cut the result to 4.
        let ownedAll = (1...10).map { card("o\($0)", set: "S\($0)") }
        let profile = DiscoverAffinity.profile(owned: ownedAll, wanted: [], dexIds: [:])
        let candidates = (1...10).map { card("c\($0)", set: "S\($0)") }
        let ranked = DiscoverAffinity.rank(candidates: candidates, dexIds: [:], profile: profile, perGroupCap: 3, limit: 4)
        XCTAssertEqual(ranked.count, 4)
    }

    func testDiversityCapPerSpecies() {
        // profile favors species 25. Five candidates in DISTINCT sets (so the per-set cap
        // never binds) but ALL mapping to species 25 → the per-species cap limits the result.
        let owned = [card("o1", set: "A")]
        let p = DiscoverAffinity.profile(owned: owned, wanted: [], dexIds: ["o1": [25]])
        let candidates = (1...5).map { card("c\($0)", set: "S\($0)") }
        let dex = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, [25]) })
        let ranked = DiscoverAffinity.rank(candidates: candidates, dexIds: dex, profile: p, perGroupCap: 3, limit: 30)
        XCTAssertEqual(ranked.count, 3) // capped at 3 per species
    }

    func testDiversityCapPerArtist() {
        // profile favors artist "Ken". Five candidates by "Ken" in DISTINCT sets (per-set cap
        // won't bind) and no dex (per-species cap won't bind) → the per-artist cap limits the
        // result so one prolific artist can't flood the ranking.
        let owned = [card("o1", set: "A", artist: "Ken")]
        let p = DiscoverAffinity.profile(owned: owned, wanted: [], dexIds: [:])
        let candidates = (1...5).map { card("c\($0)", set: "S\($0)", artist: "Ken") }
        let ranked = DiscoverAffinity.rank(candidates: candidates, dexIds: [:], profile: p, perGroupCap: 3, limit: 30)
        XCTAssertEqual(ranked.count, 3) // capped at 3 per artist
    }

    // MARK: - For You caption reasons

    /// Profile that likes: species 6 ("Charizard"), artist "Ken", set "A".
    private var tasteProfile: DiscoverAffinity.Profile {
        DiscoverAffinity.profile(owned: [card("o1", set: "A", artist: "Ken")], wanted: [], dexIds: ["o1": [6]])
    }

    func testReasonFullArtWinsOverEverything() {
        // A full-art card that ALSO matches a liked species must read as a full-art find (user choice).
        let c = card("c1", set: "A", artist: "Ken", rarity: "Illustration rare")
        let r = DiscoverAffinity.forYouReason(card: c, cardDexIds: [6], speciesNames: [6: "Charizard"],
                                              profile: tasteProfile, priceUsd: 500, referencePrice: 20)
        XCTAssertEqual(r, "✨ Full-art find")
    }

    func testReasonSpeciesWhenNotFullArt() {
        let c = card("c1", set: "Z", artist: "Nobody", rarity: "Common")
        let r = DiscoverAffinity.forYouReason(card: c, cardDexIds: [6], speciesNames: [6: "Charizard"],
                                              profile: tasteProfile, priceUsd: nil, referencePrice: nil)
        XCTAssertEqual(r, "Because you like Charizard")
    }

    func testReasonArtistWhenNoSpeciesMatch() {
        let c = card("c1", set: "Z", artist: "Ken", rarity: "Common")
        let r = DiscoverAffinity.forYouReason(card: c, cardDexIds: [999], speciesNames: [:],
                                              profile: tasteProfile, priceUsd: nil, referencePrice: nil)
        XCTAssertEqual(r, "More from Ken")
    }

    func testReasonChasePriceWhenNoTasteMatch() {
        let c = card("c1", set: "Z", artist: "Nobody", rarity: "Common")
        let r = DiscoverAffinity.forYouReason(card: c, cardDexIds: [], speciesNames: [:],
                                              profile: tasteProfile, priceUsd: 420, referencePrice: 20)
        XCTAssertEqual(r, "🔥 Chase pick · $420")
    }

    func testReasonFallbackWhenNothingMatches() {
        let c = card("c1", set: "Z", artist: "Nobody", rarity: "Common")
        let r = DiscoverAffinity.forYouReason(card: c, cardDexIds: [], speciesNames: [:],
                                              profile: tasteProfile, priceUsd: nil, referencePrice: nil)
        XCTAssertEqual(r, "Something new to try")
    }

    func testTiebreakByIdAscendingOnEqualScore() {
        // Two candidates in the same favored set → equal score; result must be id-ascending.
        let owned = [card("o1", set: "A")]
        let p = DiscoverAffinity.profile(owned: owned, wanted: [], dexIds: [:])
        let candidates = [card("bbb", set: "A"), card("aaa", set: "A")]
        let ranked = DiscoverAffinity.rank(candidates: candidates, dexIds: [:], profile: p, perGroupCap: 3, limit: 30)
        XCTAssertEqual(ranked.map(\.id), ["aaa", "bbb"]) // lower id first on tie
    }
}
