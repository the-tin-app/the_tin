import Foundation

/// Outbound marketplace URLs for the card-detail links section. Pure string building —
/// URLComponents does the escaping. Plain links today; affiliate params can bolt on later.
enum MarketplaceLinks {
    static func ebayCurrent(name: String, setName: String?, number: String) -> URL {
        ebay(query: query(name: name, setName: setName, number: number), sold: false)
    }

    static func ebaySold(name: String, setName: String?, number: String) -> URL {
        ebay(query: query(name: name, setName: setName, number: number), sold: true)
    }

    /// Product page when the catalog knows the TCGplayer id, else a scoped search.
    static func tcgplayer(tcgplayerId: Int?, name: String, number: String) -> URL {
        if let id = tcgplayerId { return URL(string: "https://www.tcgplayer.com/product/\(id)")! }
        var c = URLComponents(string: "https://www.tcgplayer.com/search/pokemon/product")!
        c.queryItems = [URLQueryItem(name: "q", value: "\(name) \(number)"),
                        URLQueryItem(name: "productLineName", value: "pokemon")]
        return c.url!
    }

    /// Terms that turn a hunt into a disappointment. A fixed constant, not configuration —
    /// there is no user for whom "show me the proxies" is the right answer, and a settings
    /// screen for it would cost more than the whole feature.
    static let huntNegativeKeywords = [
        "proxy", "repro", "reproduction", "custom", "fake", "digital",
        "lot", "bundle", "playtest", "orica", "metal", "sticker",
    ]

    /// The `total` to hand `ebayHunt`, from a set's **printed** total (`CatalogStore.printedTotal`,
    /// NOT `SetRecord.total` — the catalog count is inflated past the printed denominator by
    /// secret rares, and a wrong denominator returns zero results silently).
    ///
    /// Only mainline numbered sets print a denominator. A promo's number (`SWSH223`) is already
    /// unique on its own, and "SWSH223/307" matches no real listing title — real ones say
    /// "SWSH223 Promo". Numeric numbers only; nil printed total means no denominator, not a guess.
    static func denominator(number: String, printedTotal: Int?) -> String? {
        guard let printedTotal, !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        return String(printedTotal)
    }

    /// The precise search for a card you are actually buying: exact printing, collector
    /// number, buy-it-now only, cheapest first, capped at your budget, with the junk
    /// listings excluded. This is the part of Hunting that only The Tin can build — it is
    /// the only thing that holds the printing, the number and the set together.
    ///
    /// Deliberately carries NO `_sacat` category filter: a wrong category id returns the
    /// wrong listings silently instead of erroring, and the name + number + negatives
    /// already scope this hard. Add one only after verifying it against live eBay by hand.
    ///
    /// No printing qualifier either — a wishlist entry has no printing, only a card id, and
    /// where the catalog separates printings it separates them BY id. There is nothing to
    /// pass. (`CardVariant` records what you own, not what you want.)
    ///
    /// `minCondition` is deliberately absent: eBay's condition aspects are inconsistently
    /// populated on singles, so filtering on them loses real listings. It stays a display
    /// fact on the Hunting row.
    static func ebayHunt(name: String, setName: String?, number: String, total: String?,
                         maxUsd: Double?) -> URL {
        let collector = total.map { "\(number)/\($0)" } ?? number
        let positives = [name, collector, setName].compactMap { $0 }
        // A negative that appears in a POSITIVE term cancels the query it belongs to:
        // "Metal Energy … -metal" excludes every listing that could possibly match, and eBay
        // reports that as "nothing for sale". Dropping the colliding negative loses one filter;
        // keeping it loses every result, so the drop always wins. Checked against the set name
        // as well as the card name — both are required terms, so both cancel the same way.
        let words = Set(positives.joined(separator: " ").lowercased()
            .split { !$0.isLetter }.map(String.init))
        let negatives = huntNegativeKeywords.filter { !words.contains($0) }.map { "-\($0)" }
        var c = URLComponents(string: "https://www.ebay.com/sch/i.html")!
        var items = [
            URLQueryItem(name: "_nkw", value: (positives + negatives).joined(separator: " ")),
            URLQueryItem(name: "LH_BIN", value: "1"),   // buy it now — an auction isn't a decision
            URLQueryItem(name: "_sop", value: "15"),    // price + shipping, lowest first
        ]
        // No budget means no ceiling. A `_udhi` of 0 would return an empty page that reads
        // as "none exist", which is a lie about the market.
        if let maxUsd { items.append(URLQueryItem(name: "_udhi", value: money(maxUsd))) }
        c.queryItems = items
        return c.url!
    }

    /// Whole dollars stay whole ("300", not "300.0"); anything else gets exactly two places.
    ///
    /// `en_US_POSIX` is explicit rather than relying on `String(format:)`'s default
    /// non-localized behaviour — this string goes into a URL query, where a comma decimal
    /// separator would be percent-encoded and silently rejected, and the default is subtle
    /// enough to be misread.
    private static func money(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v))
                          : String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), v)
    }

    private static func query(name: String, setName: String?, number: String) -> String {
        [name, setName, number].compactMap { $0 }.joined(separator: " ")
    }

    private static func ebay(query: String, sold: Bool) -> URL {
        var c = URLComponents(string: "https://www.ebay.com/sch/i.html")!
        var items = [URLQueryItem(name: "_nkw", value: query)]
        if sold {
            items += [URLQueryItem(name: "LH_Sold", value: "1"),
                      URLQueryItem(name: "LH_Complete", value: "1")]
        }
        c.queryItems = items
        return c.url!
    }
}
