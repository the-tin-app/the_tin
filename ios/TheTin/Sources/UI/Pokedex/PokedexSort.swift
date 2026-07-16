import Foundation

enum PokemonSort: String, CaseIterable, Identifiable {
    case dex, alphabetical, mostOwned
    var id: String { rawValue }
    var label: String { self == .dex ? "Dex #" : self == .alphabetical ? "A–Z" : "Most owned" }
}

enum PokedexSort {
    static func sorted(pokemon: [PokemonRecord], ownedCounts: [Int: Int], by sort: PokemonSort) -> [PokemonRecord] {
        switch sort {
        case .dex: return pokemon.sorted { $0.dexId < $1.dexId }
        case .alphabetical: return pokemon.sorted { $0.name < $1.name }
        case .mostOwned: return pokemon.sorted { (ownedCounts[$0.dexId] ?? 0) > (ownedCounts[$1.dexId] ?? 0) }
        }
    }
}
