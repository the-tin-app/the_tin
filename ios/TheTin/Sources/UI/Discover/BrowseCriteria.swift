import Foundation

/// Sort order for the Browse stream. `relevance` = catalog id order (stable, price-agnostic).
enum BrowseSort: String, Codable, CaseIterable, Hashable {
    case relevance, priceAsc, priceDesc, biggestDrop
    var label: String {
        switch self {
        case .relevance:   return "Relevance"
        case .priceAsc:    return "Price: low → high"
        case .priceDesc:   return "Price: high → low"
        case .biggestDrop: return "Biggest drop"
        }
    }
}

/// The full window-shopper filter. Empty sets / nil bounds / false toggles = unconstrained on
/// that axis. `Hashable` so `DiscoverBrowseView` can key the deck on it; `Codable` so presets persist.
struct BrowseCriteria: Hashable, Codable {
    var eras: Set<String> = []
    var rarities: Set<String> = []
    var types: Set<String> = []
    var minPrice: Double? = nil
    var maxPrice: Double? = nil
    var dealsOnly: Bool = false
    var hideOwned: Bool = false
    var sort: BrowseSort = .relevance

    /// True when nothing is constrained — browse everything in id order.
    var isDefault: Bool {
        eras.isEmpty && rarities.isEmpty && types.isEmpty
            && minPrice == nil && maxPrice == nil
            && !dealsOnly && !hideOwned && sort == .relevance
    }
}
