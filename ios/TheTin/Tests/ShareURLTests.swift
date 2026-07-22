import XCTest
@testable import TheTin

final class ShareURLTests: XCTestCase {
    private func card(id: String, name: String) -> CardRecord {
        CardRecord(id: id, setId: "base1", number: "4", name: name, hp: nil, types: [],
                   rarity: nil, artist: nil,
                   imageBase: "https://assets.tcgdex.net/en/base/base1/4", imageUrl: nil, tcgplayerId: nil)
    }

    func testURLHasHostPathAndEncodedParams() {
        let url = CardShareLink.url(card: card(id: "base1-4", name: "Charizard & Friends"), setName: "Base Set")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.host, "thetinapp.com")
        XCTAssertEqual(comps.path, "/c/base1-4")
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["n"], "Charizard & Friends")            // decoded value round-trips
        XCTAssertEqual(items["set"], "Base Set")
        XCTAssertEqual(items["img"], "https://assets.tcgdex.net/en/base/base1/4/high.webp")
        // The raw string must percent-encode the space and ampersand
        XCTAssertTrue(url.absoluteString.contains("n=Charizard%20%26%20Friends")
                      || url.absoluteString.contains("n=Charizard+%26+Friends"))
    }

    func testSetNameOmittedWhenNil() {
        let url = CardShareLink.url(card: card(id: "x-1", name: "Pikachu"), setName: nil)
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []).map(\.name)
        XCTAssertFalse(names.contains("set"))
        XCTAssertTrue(names.contains("n"))
    }
}
