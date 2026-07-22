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
}
