import Foundation

/// RFC 4180 CSV writer + the two export surfaces (collection, wishlist). Pure — no I/O, no UI.
enum CollectionCSV {
    static let header = ["card_id", "name", "set_id", "set_name", "number", "rarity", "qty",
                         "variant", "condition", "grade", "price_paid", "acquired_at",
                         "acquired_from", "added_at", "divider", "current_value", "value_as_of"]

    /// ISO 8601 with time, UTC — every exported date column uses this.
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// RFC 4180: quote a field containing comma, quote, or line break; double embedded quotes.
    static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func write(_ rows: [[String]]) -> String {
        rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// UTF-8 BOM + CSV text — the BOM makes Excel open the file as UTF-8.
    static func data(_ rows: [[String]]) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(write(rows).utf8)
    }

    /// "the-tin-collection" → "the-tin-collection-2026-07-14" (UTC date — deterministic).
    static func filename(_ base: String, on date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return "\(base)-\(f.string(from: date))"
    }

    private static func money(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
    private static func date(_ d: Date?) -> String { d.map(iso.string(from:)) ?? "" }

    /// One row per entry. Catalog joins come in as prebuilt dictionaries (caller fetches once);
    /// current_value is GroupStats.entryValue — condition/grade/variant aware, the number the
    /// app shows. Unknown cards export with blank catalog columns rather than failing the file.
    static func export(entries: [CollectionEntry], groups: [CardGroup],
                       cards: [String: CardRecord], sets: [String: SetRecord],
                       prices: [String: PriceRecord],
                       variantsByCard: [String: [VariantPrice]] = [:],
                       conditionsByCard: [String: [ConditionPrice]] = [:],
                       matrixByCard: [String: [MatrixPrice]] = [:],
                       gradedByPrintingByCard: [String: [GradedPrintingPrice]] = [:]) -> Data {
        let groupName = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        let rows = entries.map { e -> [String] in
            let card = cards[e.cardId]
            let set = card.flatMap { sets[$0.setId] }
            let price = prices[e.cardId]
            let value = GroupStats.entryValue(e, price: price,
                                              variants: variantsByCard[e.cardId] ?? [],
                                              conditions: conditionsByCard[e.cardId] ?? [],
                                              matrix: matrixByCard[e.cardId] ?? [],
                                              gradedByPrinting: gradedByPrintingByCard[e.cardId] ?? [])
            return [e.cardId, card?.name ?? "", card?.setId ?? "", set?.name ?? "",
                    card?.number ?? "", card?.rarity ?? "", String(e.qty),
                    e.variant ?? "", e.condition ?? "", e.grade ?? "",
                    money(e.pricePaid), date(e.acquiredAt), e.acquiredFrom ?? "", date(e.addedAt),
                    groupName[e.groupId] ?? "", money(value),
                    value == nil ? "" : (price?.asOf ?? "")]
        }
        return data([header] + rows)
    }

    static let wishlistHeader = ["card_id", "name", "set_id", "set_name", "number",
                                 "market_usd", "as_of"]

    /// Wishlist export: one row per wanted card, raw (ungraded) market price.
    static func exportWishlist(cards: [CardRecord], sets: [String: SetRecord],
                               prices: [String: PriceRecord]) -> Data {
        let rows = cards.map { c -> [String] in
            let p = prices[c.id]
            return [c.id, c.name, c.setId, sets[c.setId]?.name ?? "", c.number,
                    money(p?.rawUsd), p?.rawUsd == nil ? "" : (p?.asOf ?? "")]
        }
        return data([wishlistHeader] + rows)
    }
}
