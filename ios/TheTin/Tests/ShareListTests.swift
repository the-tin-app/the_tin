import XCTest
@testable import TheTin

final class ShareListTests: XCTestCase {
    /// Realistic shape: ids, names and a set name, which is what actually decides how many cards
    /// fit in a link.
    private func items(_ n: Int) -> [ShareList.Item] {
        (0..<n).map { ShareList.Item(c: "sv3pt5-\($0)", n: "Pikachu ex \($0)",
                                     s: "Scarlet & Violet 151") }
    }

    func testRoundTripsAWantList() throws {
        let payload = ShareList.Payload(k: .want, i: [
            ShareList.Item(c: "base1-4", n: "Charizard", s: "Base Set", t: 250, p: "high"),
            ShareList.Item(c: "swsh7-215"),
        ])
        let decoded = try ShareList.decode(try ShareList.encode(payload))
        XCTAssertEqual(decoded, payload)
    }

    func testRoundTripsATradeList() throws {
        let payload = ShareList.Payload(k: .trade, i: [
            ShareList.Item(c: "base1-4", n: "Charizard", s: "Base Set", q: 3, d: "NM"),
        ])
        let decoded = try ShareList.decode(try ShareList.encode(payload))
        XCTAssertEqual(decoded, payload)
    }

    /// THE privacy assertion. The encoded payload must contain the card ids and nothing that
    /// could identify who made it. If someone adds a field to `Payload`, this fails.
    func testPayloadCarriesNothingButTheCards() throws {
        let payload = ShareList.Payload(k: .want, i: [
            ShareList.Item(c: "base1-4", n: "Charizard", s: "Base Set", t: 250, p: "high")])
        let encoded = try ShareList.encode(payload)
        let json = String(decoding: try ShareList.data(fromBase64URL: encoded)!.gunzipped(),
                          as: UTF8.self)
        // Whole-payload equality (keys sorted, per `encode`): any new key shows up here and has
        // to be justified before this test can be updated.
        XCTAssertEqual(json, #"{"i":[{"c":"base1-4","n":"Charizard","p":"high","s":"Base Set","t":250}],"k":"want","v":1}"#)
    }

    /// Two people wanting the same cards must produce the same link — no salt, no timestamp, no
    /// device id hiding in the bytes.
    func testTheSameListAlwaysEncodesIdentically() throws {
        let a = try ShareList.encode(ShareList.Payload(k: .want, i: items(20)))
        let b = try ShareList.encode(ShareList.Payload(k: .want, i: items(20)))
        XCTAssertEqual(a, b)
    }

    func testLinkHasHostPathAndPayloadParameter() throws {
        let link = try ShareList.link(kind: .want, items: items(3))
        let comps = try XCTUnwrap(URLComponents(url: link.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.scheme, "https")
        XCTAssertEqual(comps.host, "thetinapp.com")
        XCTAssertEqual(comps.path, "/l")
        XCTAssertEqual(comps.queryItems?.first?.name, "d")
        XCTAssertEqual(link.included, 3)
    }

    /// base64url only: `+`, `/` and `=` would each be percent-encoded in a query string, inflating
    /// the link by roughly a third and eating the card budget.
    func testEncodedPayloadIsURLSafeAndNeedsNoPercentEncoding() throws {
        let link = try ShareList.link(kind: .trade, items: items(60))
        let raw = try XCTUnwrap(URLComponents(url: link.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first?.value)
        XCTAssertFalse(raw.contains("+"))
        XCTAssertFalse(raw.contains("/"))
        XCTAssertFalse(raw.contains("="))
        XCTAssertFalse(link.url.absoluteString.contains("%"))
    }

    /// A link that silently breaks when pasted into Discord is worse than a short one, so a long
    /// list is truncated to what fits — and the caller is told how much made it.
    func testAnOversizedListIsTruncatedToWhatFits() throws {
        let link = try ShareList.link(kind: .want, items: items(4000))
        XCTAssertLessThanOrEqual(link.url.absoluteString.count, ShareList.maxURLLength)
        XCTAssertGreaterThan(link.included, 0)
        XCTAssertLessThan(link.included, 4000)

        // What survived is the FRONT of the list — callers pass it value-descending, so the
        // cards worth talking about are the ones that make it.
        let decoded = try ShareList.decode(
            try XCTUnwrap(URLComponents(url: link.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first?.value))
        XCTAssertEqual(decoded.i.map(\.c), items(link.included).map(\.c))
    }

    /// A realistic want list — the size a shop meetup actually involves — must not truncate.
    func testATypicalListFitsWhole() throws {
        let link = try ShareList.link(kind: .want, items: items(100))
        XCTAssertEqual(link.included, 100, "100 cards should fit in a link")
    }

    func testEmptyListStillProducesAValidLink() throws {
        let link = try ShareList.link(kind: .want, items: [])
        XCTAssertEqual(link.included, 0)
        XCTAssertEqual(try ShareList.decode(
            try XCTUnwrap(URLComponents(url: link.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first?.value)).i, [])
    }

    /// Cross-language interop. This string was produced by Node's zlib — the same gzip the
    /// Cloudflare Pages Function at `site/functions/l.js` decodes with `DecompressionStream`. If
    /// Swift reads it, the two sides agree on the wire format, which is the only thing standing
    /// between a shared link and a blank page on someone else's phone.
    func testDecodesAPayloadProducedByTheWebSide() throws {
        let fromNode = "H4sIAAAAAAACEy3MwQqCQBRA0V-Rux4hJQnerqJlm4QIosWrBmdQrBxTUvz3iDwfcEY8ch65IVw12CReYqgRtk4bP2hzxxAQNhpslNsWwxPB-cJhaJE0W0zmP4Q-uFWcJtl8HPTzeuug0XG_Ps3PrntUna-LKC-9DUwXQ4nQa_2rOySZvp5br3qVAAAA"
        let decoded = try ShareList.decode(fromNode)
        XCTAssertEqual(decoded.v, 1)
        XCTAssertEqual(decoded.k, .want)
        XCTAssertEqual(decoded.i.map(\.c), ["base1-4", "swsh7-215"])
        XCTAssertEqual(decoded.i.first?.n, "Charizard")
        XCTAssertEqual(decoded.i.first?.s, "Base Set")
        XCTAssertEqual(decoded.i.first?.t, 250)
        XCTAssertEqual(decoded.i.first?.p, "high")
    }

    func testGarbagePayloadThrowsRatherThanCrashing() {
        XCTAssertThrowsError(try ShareList.decode("not-a-payload"))
        XCTAssertThrowsError(try ShareList.decode(""))
    }

    func testBase64URLRoundTripsAcrossPaddingLengths() throws {
        for length in 1...8 {
            let data = Data(repeating: 0xAB, count: length)
            let encoded = ShareList.base64URL(data)
            XCTAssertEqual(ShareList.data(fromBase64URL: encoded), data, "length \(length)")
        }
    }
}
