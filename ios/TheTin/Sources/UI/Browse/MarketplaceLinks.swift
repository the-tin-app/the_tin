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
        let negatives = huntNegativeKeywords.map { "-\($0)" }
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
    private static func money(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
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
