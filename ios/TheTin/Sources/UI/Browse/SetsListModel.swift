import Foundation
import Observation

enum SetSort: String, CaseIterable, Identifiable {
    case recent, oldest, mostValuable, mostOwned
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recent: return "Newest"; case .oldest: return "Oldest"
        case .mostValuable: return "Most valuable"; case .mostOwned: return "Most owned"
        }
    }
}

enum SetCategory: String { case major = "Major Sets", other = "Other Sets" }

struct SetSection: Identifiable {
    let id: String
    let category: SetCategory
    let year: String
    let isFirstOfCategory: Bool
    let sets: [SetRecord]
}

@MainActor @Observable
final class SetsListModel {
    var sort: SetSort = .recent

    /// Era names that are promos / side products / other games rather than mainline expansions.
    private static let otherEras: Set<String> = [
        "Trainer kits", "McDonald's Collection", "POP", "Pokémon TCG Pocket",
    ]

    nonisolated static func category(of set: SetRecord) -> SetCategory {
        guard let era = set.era, otherEras.contains(era) else { return .major }
        return .other
    }

    nonisolated static func sorted(sets: [SetRecord], rawTotals: [String: Double],
                       ownedCounts: [String: Int], by sort: SetSort) -> [SetRecord] {
        switch sort {
        case .recent: return sets.sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
        case .oldest: return sets.sorted { ($0.releaseDate ?? "") < ($1.releaseDate ?? "") }
        case .mostValuable: return sets.sorted { (rawTotals[$0.id] ?? 0) > (rawTotals[$1.id] ?? 0) }
        case .mostOwned: return sets.sorted { (ownedCounts[$0.id] ?? 0) > (ownedCounts[$1.id] ?? 0) }
        }
    }

    /// Major/Other, then by release year, preserving the chosen sort's order within each year.
    nonisolated static func sections(sets: [SetRecord], rawTotals: [String: Double],
                                      ownedCounts: [String: Int], by sort: SetSort) -> [SetSection] {
        let ordered = sorted(sets: sets, rawTotals: rawTotals, ownedCounts: ownedCounts, by: sort)
        var result: [SetSection] = []
        for category: SetCategory in [.major, .other] {
            var yearOrder: [String] = []
            var byYear: [String: [SetRecord]] = [:]
            for set in ordered where Self.category(of: set) == category {
                let year = set.releaseDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } ?? "Unknown"
                if byYear[year] == nil { yearOrder.append(year) }
                byYear[year, default: []].append(set)
            }
            for (i, year) in yearOrder.enumerated() {
                result.append(SetSection(id: "\(category.rawValue)-\(year)", category: category, year: year,
                                          isFirstOfCategory: i == 0, sets: byYear[year] ?? []))
            }
        }
        return result
    }
}
