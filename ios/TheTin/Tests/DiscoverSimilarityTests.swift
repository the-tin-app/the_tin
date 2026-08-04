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
}
