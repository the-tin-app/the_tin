import Foundation

enum WishlistSort: String, CaseIterable, Identifiable {
    case priority, recentlyAdded, onSale, cheapest, expensive, releasedNewest, name
    var id: String { rawValue }
    var label: String {
        switch self {
        case .priority: return "Priority"
        case .recentlyAdded: return "Recently added"
        case .onSale: return "On sale"
        case .cheapest: return "Cheapest"
        case .expensive: return "Most expensive"
        case .releasedNewest: return "Newest"
        case .name: return "A–Z"
        }
    }
}

enum WishlistGrid {
    /// `prices` is raw USD market (nil = unpriced → sorts last for price-based orders);
    /// `entries` carries priority/target/addedAt; `setDates` maps setId → release-date string.
    static func sorted(cards: [CardRecord], entries: [String: WantEntry],
                       prices: [String: Double], setDates: [String: String],
                       by sort: WishlistSort) -> [CardRecord] {
        func price(_ c: CardRecord) -> Double? { prices[c.id] }
        func entry(_ c: CardRecord) -> WantEntry { entries[c.id] ?? WantEntry() }
        // (0, discount) for at/under-target cards (discount = price-target, more negative = deeper),
        // (1, 0) otherwise — so on-sale cards lead, deepest discount first.
        func onSaleKey(_ c: CardRecord) -> (Int, Double) {
            guard let t = entry(c).targetUsd, let p = price(c), p <= t else { return (1, 0) }
            return (0, p - t)
        }
        switch sort {
        case .priority:
            return cards.sorted {
                let a = entry($0), b = entry($1)
                if a.priority != b.priority { return a.priority.rawValue < b.priority.rawValue }
                return (price($0) ?? -1) > (price($1) ?? -1)
            }
        case .recentlyAdded:
            return cards.sorted { entry($0).addedAt > entry($1).addedAt }
        case .onSale:
            return cards.sorted {
                let ka = onSaleKey($0), kb = onSaleKey($1)
                if ka.0 != kb.0 { return ka.0 < kb.0 }
                if ka.0 == 0 { return ka.1 < kb.1 }
                return $0.name < $1.name
            }
        case .cheapest:
            return cards.sorted { (price($0) ?? .greatestFiniteMagnitude) < (price($1) ?? .greatestFiniteMagnitude) }
        case .expensive:
            return cards.sorted { (price($0) ?? -1) > (price($1) ?? -1) }
        case .releasedNewest:
            return cards.sorted { (setDates[$0.setId] ?? "") > (setDates[$1.setId] ?? "") }
        case .name:
            return cards.sorted { $0.name < $1.name }
        }
    }

    /// Market price is at or below target (needs both a target and a known price).
    static func isOnSale(_ card: CardRecord, entry: WantEntry?, price: Double?) -> Bool {
        guard let t = entry?.targetUsd, let p = price else { return false }
        return p <= t
    }
}
