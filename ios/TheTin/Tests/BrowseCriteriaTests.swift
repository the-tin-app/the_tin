import XCTest
@testable import TheTin

final class BrowseCriteriaTests: XCTestCase {
    func testDefaultIsDefault() {
        XCTAssertTrue(BrowseCriteria().isDefault)
    }

    func testNonDefaultWhenAnyAxisSet() {
        var c = BrowseCriteria()
        c.rarities = ["Secret Rare"]
        XCTAssertFalse(c.isDefault)
    }

    func testCodableRoundTrip() throws {
        var c = BrowseCriteria()
        c.eras = ["Scarlet & Violet"]
        c.rarities = ["Illustration rare"]
        c.types = ["Fire"]
        c.minPrice = 5; c.maxPrice = 50
        c.dealsOnly = true; c.hideOwned = true
        c.sort = .biggestDrop
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(BrowseCriteria.self, from: data)
        XCTAssertEqual(c, back)
    }

    func testConstantsPresent() {
        XCTAssertLessThan(DiscoverConstants.dealsMaxPct7d, 0)
        XCTAssertTrue(DiscoverConstants.energyTypes.contains("Fire"))
    }

    func testRegionRangesAreContiguousAndCoverDex() {
        let regions = PokemonRegion.all
        XCTAssertEqual(regions.map(\.gen), Array(1...9), "one region per generation 1…9")
        XCTAssertEqual(regions.first?.lo, 1, "national dex starts at 1")
        // No gaps, no overlaps: each region begins exactly one past the previous region's end.
        for (prev, next) in zip(regions, regions.dropFirst()) {
            XCTAssertEqual(next.lo, prev.hi + 1, "gap/overlap between gen \(prev.gen) and gen \(next.gen)")
        }
        XCTAssertEqual(regions.last?.hi, 1025, "covers through the current dex maximum")
    }

    func testRegionLabel() {
        XCTAssertEqual(PokemonRegion.all.first?.label, "Kanto · Gen 1")
    }

    func testRegionsAxisAffectsIsDefaultAndRoundTrips() throws {
        var c = BrowseCriteria()
        c.regions = [1, 3]
        XCTAssertFalse(c.isDefault)
        let back = try JSONDecoder().decode(BrowseCriteria.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(c, back)
    }
}
