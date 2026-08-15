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
        XCTAssertEqual(items["img"], "https://assets.tcgdex.net/en/base/base1/4/high.png")
        // The raw string must percent-encode the space and ampersand
        XCTAssertTrue(url.absoluteString.contains("n=Charizard%20%26%20Friends")
                      || url.absoluteString.contains("n=Charizard+%26+Friends"))
    }

    /// The old inline rule was imageBase-then-imageUrl, which skipped the TCGplayer CDN entirely —
    /// so every card TCGdex has no art for shared with no preview image at all.
    func testACardWithoutTCGdexArtStillGetsAPreviewImage() {
        let noTCGdex = CardRecord(id: "mep-046", setId: "mep", number: "46", name: "Chikorita",
                                  hp: nil, types: [], rarity: nil, artist: nil,
                                  imageBase: nil, imageUrl: nil, tcgplayerId: 517_123)
        let items = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: CardShareLink.url(card: noTCGdex, setName: nil),
                           resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["img"],
                       "https://tcgplayer-cdn.tcgplayer.com/product/517123_in_800x800.jpg")
    }

    func testSetNameOmittedWhenNil() {
        let url = CardShareLink.url(card: card(id: "x-1", name: "Pikachu"), setName: nil)
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []).map(\.name)
        XCTAssertFalse(names.contains("set"))
        XCTAssertTrue(names.contains("n"))
    }
}
