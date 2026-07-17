import XCTest
@testable import TheTin

final class CardSearchIndexTests: XCTestCase {
    func testTokenMatch() {
        let hay = "swsh7-215 Umbreon VMAX swsh7 215 Evolving Skies"
        XCTAssertTrue(CardSearchIndex.tokenMatch(haystack: hay, query: "umbreon"))
        XCTAssertTrue(CardSearchIndex.tokenMatch(haystack: hay, query: "215"))
        XCTAssertTrue(CardSearchIndex.tokenMatch(haystack: hay, query: "evolving skies"))
        XCTAssertTrue(CardSearchIndex.tokenMatch(haystack: hay, query: "swsh7 umbreon"))   // any order
        XCTAssertFalse(CardSearchIndex.tokenMatch(haystack: hay, query: "umbreon 216"))    // all tokens must hit
        XCTAssertFalse(CardSearchIndex.tokenMatch(haystack: hay, query: "charizard"))
    }
}
