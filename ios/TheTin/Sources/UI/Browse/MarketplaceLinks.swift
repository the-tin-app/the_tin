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
    ///
    /// Both spellings of fan art are listed because sellers use both freely, and neither is
    /// covered by "custom" or "proxy" — a fan-art card is not sold as a reproduction of a real
    /// one, so it clears every other filter here and lands at the top of a cheapest-first hunt.
    static let huntNegativeKeywords = [
        "proxy", "repro", "reproduction", "custom", "fake", "digital",
        "lot", "bundle", "playtest", "orica", "metal", "sticker",
        "fan art", "fanart",
        // Merchandise wearing the card's name. Every one of these was observed at the top of a
        // live Charizard 4/102 hunt on 2026-07-29: novelty keychains, a fridge magnet, a wooden
        // jumbo, and a "gold foil display card". They are not cards, they clear every filter
        // above, and being cheap they sort to the very top of a cheapest-first search.
        "keychain", "magnet", "novelty", "jumbo", "display", "wooden", "gold foil",
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
    /// Scoped to `_sacat=183454` (CCG Individual Cards). This was deliberately absent until
    /// **verified against live eBay by hand on 2026-07-29** — a wrong category id returns the
    /// wrong listings silently instead of erroring, so it could not be adopted on reasoning.
    /// What the check showed: without it a Charizard 4/102 hunt opened on a $4.44 novelty
    /// keychain; with it, on a $44.64 card. It does structurally what the merch negatives below
    /// do by keyword, and the negatives stay anyway because the category is a *seller-declared*
    /// field and miscategorised junk is exactly the junk that reaches the top of a cheap sort.
    ///
    /// `_udlo` floors the price at a fraction of what the card is actually worth — see
    /// `priceFloor`. Counterfeits don't say they're counterfeits, so no keyword can catch them;
    /// the price is the only tell, and The Tin is the rare tool that already knows it.
    ///
    /// No printing qualifier either — a wishlist entry has no printing, only a card id, and
    /// where the catalog separates printings it separates them BY id. There is nothing to
    /// pass. (`CardVariant` records what you own, not what you want.)
    ///
    /// `minCondition` is deliberately absent: eBay's condition aspects are inconsistently
    /// populated on singles, so filtering on them loses real listings. It stays a display
    /// fact on the Hunting row.
    /// eBay's "CCG Individual Cards" category — singles only, so merchandise bearing a card's
    /// name (keychains, magnets, fridge art) is out of scope structurally.
    static let ebayCardCategory = "183454"

    /// A listing under this fraction of the card's market price is a counterfeit or a novelty,
    /// not a bargain. Low enough that a genuinely beaten-up copy still clears it: a heavily
    /// played Base Set Charizard trades around a third of a clean one, and 0.25 sits under that.
    static let huntPriceFloorFraction = 0.25

    /// The `_udlo` floor, or nil when there shouldn't be one.
    ///
    /// Two ways this must refuse to act, both because an over-tight band returns an empty page
    /// that reads as "none exist" — a lie about the market, and the same failure the `_udhi`
    /// note below guards against:
    /// - **No market price** (EUR-only or graded-only cards) — there is nothing to take a
    ///   fraction of, and a guessed floor is worse than none.
    /// - **The floor reaching the user's budget.** Hunting far below market is a legitimate,
    ///   common thing to do; `_udlo > _udhi` guarantees zero results. The budget is the user's
    ///   explicit instruction and the floor is our heuristic, so the instruction wins and the
    ///   floor is dropped — they asked for cheap, they get cheap, fakes included.
    static func priceFloor(marketUsd: Double?, maxUsd: Double?) -> Double? {
        guard let marketUsd, marketUsd > 0 else { return nil }
        let floor = marketUsd * huntPriceFloorFraction
        if let maxUsd, floor >= maxUsd { return nil }
        return floor
    }

    static func ebayHunt(name: String, setName: String?, number: String, total: String?,
                         maxUsd: Double?, marketUsd: Double? = nil) -> URL {
        let collector = total.map { "\(number)/\($0)" } ?? number
        let positives = [name, collector, setName].compactMap { $0 }
        // A negative that appears in a POSITIVE term cancels the query it belongs to:
        // "Metal Energy … -metal" excludes every listing that could possibly match, and eBay
        // reports that as "nothing for sale". Dropping the colliding negative loses one filter;
        // keeping it loses every result, so the drop always wins. Checked against the set name
        // as well as the card name — both are required terms, so both cancel the same way.
        //
        // A MULTI-word negative collides only when EVERY one of its words is a positive, so
        // "Pokémon Fan Club" keeps -"fan art" while still dropping a negative it truly contains.
        // For single-word negatives this is exactly the old rule.
        let words = Set(positives.joined(separator: " ").lowercased()
            .split { !$0.isLetter }.map(String.init))
        let negatives = huntNegativeKeywords
            .filter { !$0.split(separator: " ").allSatisfy { words.contains(String($0)) } }
            // eBay needs a phrase exclusion quoted: bare `-fan art` parses as `-fan AND art`,
            // which drops the Fan Club card AND makes "art" a required term.
            .map { $0.contains(" ") ? "-\"\($0)\"" : "-\($0)" }
        var c = URLComponents(string: "https://www.ebay.com/sch/i.html")!
        var items = [
            URLQueryItem(name: "_nkw", value: (positives + negatives).joined(separator: " ")),
            URLQueryItem(name: "_sacat", value: ebayCardCategory),  // singles, not merchandise
            URLQueryItem(name: "LH_BIN", value: "1"),   // buy it now — an auction isn't a decision
            URLQueryItem(name: "_sop", value: "15"),    // price + shipping, lowest first
        ]
        // No budget means no ceiling. A `_udhi` of 0 would return an empty page that reads
        // as "none exist", which is a lie about the market.
        if let maxUsd { items.append(URLQueryItem(name: "_udhi", value: money(maxUsd))) }
        if let floor = priceFloor(marketUsd: marketUsd, maxUsd: maxUsd) {
            items.append(URLQueryItem(name: "_udlo", value: money(floor)))
        }
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
