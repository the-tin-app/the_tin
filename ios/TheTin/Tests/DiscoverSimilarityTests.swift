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
