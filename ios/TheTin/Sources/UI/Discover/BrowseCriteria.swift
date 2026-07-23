import Foundation

/// The nine Pokémon regions, keyed by generation number (the stable value stored in
/// `BrowseCriteria.regions`). National-dex ranges are how a card's region of first appearance is
/// derived: dex numbers are assigned by first-appearance generation. Contiguous, covers 1–1025.
struct PokemonRegion: Identifiable, Hashable {
    let gen: Int
    let name: String
    let lo: Int
    let hi: Int
    var id: Int { gen }
    /// Generic, franchise-neutral label (`name` stays as internal gen↔region documentation).
    var label: String { "Gen \(gen) · #\(lo)–\(hi)" }

    static let all: [PokemonRegion] = [
        .init(gen: 1, name: "Kanto",  lo: 1,   hi: 151),
        .init(gen: 2, name: "Johto",  lo: 152, hi: 251),
        .init(gen: 3, name: "Hoenn",  lo: 252, hi: 386),
        .init(gen: 4, name: "Sinnoh", lo: 387, hi: 493),
        .init(gen: 5, name: "Unova",  lo: 494, hi: 649),
        .init(gen: 6, name: "Kalos",  lo: 650, hi: 721),
        .init(gen: 7, name: "Alola",  lo: 722, hi: 809),
        .init(gen: 8, name: "Galar",  lo: 810, hi: 905),
        .init(gen: 9, name: "Paldea", lo: 906, hi: 1025),
    ]
}

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
    var regions: Set<Int> = []
    var minPrice: Double? = nil
    var maxPrice: Double? = nil
    var dealsOnly: Bool = false
    var hideOwned: Bool = false
    var sort: BrowseSort = .relevance

    /// True when nothing is constrained — browse everything in id order.
    var isDefault: Bool {
        eras.isEmpty && rarities.isEmpty && types.isEmpty && regions.isEmpty
            && minPrice == nil && maxPrice == nil
            && !dealsOnly && !hideOwned && sort == .relevance
    }
}
