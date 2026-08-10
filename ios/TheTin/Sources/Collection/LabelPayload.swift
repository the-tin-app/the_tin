import Foundation

/// What a printed label's QR code says, and how to read one back.
///
/// ```
/// https://thetinapp.com/c/<cardId>?v=1&p=<CardVariant>&c=<CardCondition>&e=<entryId>
/// ```
///
/// This deliberately EXTENDS the share link the app has always understood. `AppModel.handleDeepLink`
/// already routes `/c/<id>` and ignores query parameters, and the website's card page is stateless
/// — so a label printed today opens the right card on every build already in users' hands,
/// including v1.0 on the App Store.
///
/// ⚠️ THIS IS A PUBLIC CONTRACT PRINTED ON PHYSICAL STICKERS. Five rules, none optional:
///
/// 1. **The card id lives in the PATH and never moves.** It is the part every future version
///    shares, so any future payload still opens the right card on any build ever shipped.
/// 2. **`v` is the format version.** Meeting an unknown `v`, ignore every parameter you don't
///    recognise and open the card anyway. Never refuse, never guess.
/// 3. **Parameters are only added, never removed or repurposed.** `p`, `c`, `e` mean this forever.
///    A new fact gets a new letter.
/// 4. **An unknown parameter is ignored, never fatal.**
/// 5. **`e` is device-local.** Entry ids are on-device UUIDs (they survive iCloud backup/restore,
///    and nothing else). Every consumer must degrade to card + printing + condition when `e`
///    resolves to nothing — and the website can never resolve it at all.
struct LabelPayload: Equatable {
    let cardId: String
    let printing: CardVariant?
    let condition: CardCondition?
    /// The exact copy. nil, or an id this device doesn't know, means "this card, this printing,
    /// this condition" — never an error.
    let entryId: String?

    /// The payload format this build writes. Bump only alongside rules 2–4 above.
    static let version = 1
    static let host = "thetinapp.com"

    static func url(cardId: String, printing: CardVariant?, condition: CardCondition?,
                    entryId: String?) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        // Encoded EXPLICITLY, not via `components.path`: a slash is a legal path character, so the
        // plain setter would let an id like "226/S-P" split into two components and open card
        // "226". No id in today's catalog contains one — this costs nothing for the ids that do
        // exist (they percent-encode to themselves) and keeps the round trip honest if the id
        // space ever widens.
        let encoded = cardId.addingPercentEncoding(withAllowedCharacters: .labelCardId) ?? cardId
        components.percentEncodedPath = "/c/\(encoded)"
        var items = [URLQueryItem(name: "v", value: String(version))]
        if let printing { items.append(URLQueryItem(name: "p", value: printing.rawValue)) }
        if let condition { items.append(URLQueryItem(name: "c", value: condition.rawValue)) }
        if let entryId { items.append(URLQueryItem(name: "e", value: entryId)) }
        components.queryItems = items
        return components.url!
    }

    /// The label for one owned copy: its own printing and condition, and its own id.
    static func url(for entry: CollectionEntry) -> URL {
        url(cardId: entry.cardId, printing: entry.variantValue,
            condition: entry.conditionValue, entryId: entry.id)
    }

    /// nil when this isn't a card link at all. A card link with nothing else on it is valid and
    /// parses to a bare open — that is what today's share links are.
    static func parse(_ url: URL) -> LabelPayload? {
        guard url.host == host else { return nil }
        // Split the STILL-ENCODED path, then decode each component. `url.pathComponents` decodes
        // first and splits second, so a "%2F" inside an id would already have become a separator.
        let parts = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "")
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[1] == "c", !parts[2].isEmpty else { return nil }
        let cardId = parts[2].removingPercentEncoding ?? String(parts[2])

        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value
        }
        // Rule 2. A payload from a FUTURE version may use these letters for something else, so
        // reading them would be a guess. The card id still works, because rule 1.
        let version = value("v").flatMap(Int.init)
        guard version == nil || version == Self.version else {
            return LabelPayload(cardId: cardId, printing: nil, condition: nil, entryId: nil)
        }
        return LabelPayload(cardId: cardId,
                            printing: value("p").flatMap(CardVariant.init(rawValue:)),
                            condition: value("c").flatMap(CardCondition.init(rawValue:)),
                            entryId: value("e"))
    }
}

private extension CharacterSet {
    /// Path-safe minus the separator: everything `urlPathAllowed` permits except "/" itself.
    static let labelCardId = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
}
