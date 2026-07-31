import Foundation
import Gzip

/// A want list or trade list, encoded into a link you can paste into Discord or Facebook.
///
/// ## The privacy contract
///
/// The payload carries **the cards and nothing else**: id, name and set name (so the page is
/// readable by someone who doesn't have the app), plus a target price or priority for wants, and
/// a quantity and condition for trades. It carries **no** user id, device id, install id, account,
/// handle, contact line, timestamp, location, or collection total. Two people hunting the same
/// twenty cards produce byte-identical links. There is nothing in one that points at you.
///
/// **Nothing is stored server-side.** No upload, no database, no account: `site/functions/l`
/// renders the page from the URL alone, the same static Cloudflare Pages setup as the `/c/:id`
/// card preview. Deleting a link means not sharing it again; there is no copy to delete.
///
/// The payload lives in the query string rather than a `#fragment`. A fragment never leaves the
/// browser — strictly more private — but Facebook and Discord crawlers cannot read one, so the
/// post would unfurl as a blank grey box. Since posting to those is the whole point, the payload
/// goes where the crawler can see it. It still names nobody, and the route is `noindex`.
enum ShareList {
    enum Kind: String, Codable {
        case want, trade

        var title: String { self == .want ? "Want List" : "For Trade" }
    }

    /// Field names are single letters because they're repeated per card. Gzip would squeeze long
    /// ones anyway, but the pre-compression size is what decides how many cards fit in a URL.
    struct Item: Codable, Equatable {
        /// Card id — the only required field. Lets a recipient WITH the app deep-link to the card.
        var c: String
        /// Card name. Carried because the recipient usually doesn't have the app, and a list of
        /// catalog ids ("sv3pt5-25") is not a want list anyone can shop from.
        var n: String?
        /// Set name — which Charizard.
        var s: String?
        /// Want: target price. Trade: unused.
        var t: Double?
        /// Want: priority ("high"/"low"; normal is the default and not worth the bytes).
        var p: String?
        /// Trade: how many you'll part with. Want: unused.
        var q: Int?
        /// Trade: condition ("NM"). Want: unused.
        var d: String?
    }

    struct Payload: Codable, Equatable {
        /// Format version, so an old link can still be read after the shape changes.
        var v: Int = 1
        var k: Kind
        var i: [Item]
    }

    /// Practical ceiling for a link that must survive Discord, iMessage and a Facebook post.
    /// Browsers and Cloudflare both allow more; the messaging apps are what actually truncate.
    static let maxURLLength = 1800

    enum ShareError: Error { case malformed }

    // MARK: encoding

    static func encode(_ payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        // Deterministic key order: without it the same list can encode to different bytes on
        // different OS versions, which quietly breaks "two people wanting the same cards produce
        // the same link" — the property that makes a link say nothing about who made it.
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(payload)
        return base64URL(try json.gzipped(level: .bestCompression))
    }

    static func decode(_ encoded: String) throws -> Payload {
        guard let gz = data(fromBase64URL: encoded) else { throw ShareError.malformed }
        return try JSONDecoder().decode(Payload.self, from: gz.gunzipped())
    }

    /// The link, plus how many items actually fit. A list too long for a URL is truncated rather
    /// than emitted whole — a link that silently breaks when pasted is worse than a short one, and
    /// the caller tells the user what was left off.
    ///
    /// `items` should arrive in the order that matters (value descending), because truncation
    /// keeps the front of the list.
    static func link(kind: Kind, items: [Item], host: String = CardShareLink.host) throws
        -> (url: URL, included: Int) {
        var lo = 0, hi = items.count
        var best: (url: URL, included: Int)?
        // Binary search the longest prefix that fits: gzip means length isn't linear in item
        // count, so stepping down one at a time could take hundreds of encodes on a big list.
        while lo <= hi {
            let mid = (lo + hi) / 2
            let url = try url(kind: kind, items: Array(items.prefix(mid)), host: host)
            if url.absoluteString.count <= maxURLLength {
                best = (url, mid)
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        // An empty list still produces a valid (empty) link rather than throwing — sharing an
        // empty want list is a strange thing to do, not an error.
        guard let best else { return (try url(kind: kind, items: [], host: host), 0) }
        return best
    }

    private static func url(kind: Kind, items: [Item], host: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/l"
        components.queryItems = [URLQueryItem(name: "d", value: try encode(Payload(k: kind, i: items)))]
        guard let url = components.url else { throw ShareError.malformed }
        return url
    }

    // MARK: base64url

    /// Base64url without padding (RFC 4648 §5) — `+/=` are all query-unsafe or get percent-encoded,
    /// which would inflate the URL by a third.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(fromBase64URL string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore the stripped padding; base64 decodes only in 4-character groups.
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}
