import Foundation

enum CardSort: String, CaseIterable, Identifiable {
    case number, alphabetical, cheapest, expensive, releasedNewest, releasedOldest, owned, wanted
    var id: String { rawValue }
    var label: String {
        switch self {
        case .number: return "Card #"; case .alphabetical: return "A–Z"
        case .cheapest: return "Cheapest"; case .expensive: return "Most expensive"
        case .releasedNewest: return "Newest"; case .releasedOldest: return "Oldest"
        case .owned: return "Owned first"; case .wanted: return "Wishlist first"
        }
    }
}
enum CardFilter: String, CaseIterable, Identifiable {
    case all, owned, wanted
    var id: String { rawValue }
    var label: String { self == .all ? "All" : self == .owned ? "Owned" : "Wishlist" }
}

enum CardGridSort {
    static func apply(cards: [CardRecord], prices: [String: Double], owned: Set<String>, wanted: Set<String>,
                      setDates: [String: String], sort: CardSort, filter: CardFilter) -> [CardRecord] {
        let filtered = cards.filter { c in
            switch filter { case .all: return true; case .owned: return owned.contains(c.id); case .wanted: return wanted.contains(c.id) }
        }
        func num(_ c: CardRecord) -> Int { Int(c.number) ?? Int.max }
        switch sort {
        case .number: return filtered.sorted { num($0) < num($1) }
        case .alphabetical: return filtered.sorted { $0.name < $1.name }
        case .cheapest: return filtered.sorted { (prices[$0.id] ?? .greatestFiniteMagnitude) < (prices[$1.id] ?? .greatestFiniteMagnitude) }
        case .expensive: return filtered.sorted { (prices[$0.id] ?? -1) > (prices[$1.id] ?? -1) }
        case .releasedNewest: return filtered.sorted { (setDates[$0.setId] ?? "") > (setDates[$1.setId] ?? "") }
        case .releasedOldest: return filtered.sorted { (setDates[$0.setId] ?? "") < (setDates[$1.setId] ?? "") }
        case .owned: return filtered.sorted { (owned.contains($0.id) ? 0 : 1) < (owned.contains($1.id) ? 0 : 1) }
        case .wanted: return filtered.sorted { (wanted.contains($0.id) ? 0 : 1) < (wanted.contains($1.id) ? 0 : 1) }
        }
    }
}
