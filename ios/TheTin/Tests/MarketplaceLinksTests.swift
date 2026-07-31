import XCTest
@testable import TheTin

final class MarketplaceLinksTests: XCTestCase {
    func testEbayCurrentEncodesQuery() throws {
        let url = MarketplaceLinks.ebayCurrent(name: "Pikachu & Zekrom", setName: "Team Up", number: "33")
        XCTAssertEqual(url.host, "www.ebay.com")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "_nkw" }?.value, "Pikachu & Zekrom Team Up 33")
        XCTAssertNil(items.first { $0.name == "LH_Sold" })
    }

    func testEbaySoldAddsSoldFiltersAndSkipsNilSetName() throws {
        let url = MarketplaceLinks.ebaySold(name: "Pikachu", setName: nil, number: "25")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "LH_Sold" }?.value, "1")
        XCTAssertEqual(items.first { $0.name == "LH_Complete" }?.value, "1")
        XCTAssertEqual(items.first { $0.name == "_nkw" }?.value, "Pikachu 25")
    }

    func testTcgplayerProductPageWhenIdKnown() {
        let url = MarketplaceLinks.tcgplayer(tcgplayerId: 88, name: "x", number: "1")
        XCTAssertEqual(url.host, "www.tcgplayer.com")
        XCTAssertEqual(url.path, "/product/88")
    }

    func testTcgplayerSearchFallbackWithoutId() throws {
        let url = MarketplaceLinks.tcgplayer(tcgplayerId: nil, name: "Pikachu", number: "025")
        XCTAssertTrue(url.path.contains("search"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "Pikachu 025")
    }
}
