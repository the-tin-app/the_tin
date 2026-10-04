import Foundation

/// How a divider's (or Everything's) cards are ordered and narrowed — #193: "I cannot find a way
/// to sort my Pokémon by type and that's essential to me." Pure over a card lookup so it's
/// testable without a catalog or a view; `GroupDetailView` supplies the lookups.

/// Entry orderings offered by the View options menu.
enum TinSort: String, CaseIterable, Identifiable {
    case newest = "Newest first", value = "Highest value", name = "A to Z"
    /// Collector order: set by release date, then the printed number within it.
    case setOldest = "Set order, oldest first", setNewest = "Set order, newest first"
    case rarity = "Rarest first", hp = "Highest HP"
    var id: String { rawValue }
}

/// One value per facet; nil = any. Single-choice on purpose: "Psychic, Stage 1" is the question
/// people sort a binder by, and a menu of checkboxes per facet is a lot of menu for that.
struct TinFilter: Equatable {
    var type: String?
    var stage: String?
    var weakness: String?
    var rarity: String?

    var isActive: Bool { type != nil || stage != nil || weakness != nil || rarity != nil }
    /// "Psychic · Stage 1" — what the summary line under the plaque says is narrowing the list.
    var summary: String {
        [type, stage, weakness.map { "Weak to \($0)" }, rarity].compactMap { $0 }.joined(separator: " · ")
    }

    func matches(_ card: CardRecord?) -> Bool {
        guard isActive else { return true }
        guard let card else { return false }
        if let type, !card.types.contains(type) { return false }
        if let stage, Self.stage(of: card) != stage { return false }
        if let weakness, !(card.detail?.weaknesses ?? []).contains(where: { $0.type == weakness }) { return false }
        if let rarity, card.rarity != rarity { return false }
        return true
    }

    /// "Basic", "Stage 1", "VMAX"… for a Pokémon; "Trainer" / "Energy" for the rest, so one facet
    /// also answers "just my Trainers". nil on catalogs older than the `detail` column.
    static func stage(of card: CardRecord) -> String? {
        switch card.detail?.category {
        case "Trainer": return "Trainer"
        case "Energy": return "Energy"
        default: return card.detail?.stage
        }
    }

    /// The values each facet can take IN THIS LIST — a menu offering "Dragon" in a divider with no
    /// Dragon cards would be a filter to an empty screen.
    struct Options: Equatable {
        var types: [String] = []
        var stages: [String] = []
        var weaknesses: [String] = []
        var rarities: [String] = []
    }

    static func options(for cards: [CardRecord]) -> Options {
        var types = Set<String>(), stages = Set<String>(), weaknesses = Set<String>(), rarities = Set<String>()
        for card in cards {
            types.formUnion(card.types)
            if let s = stage(of: card) { stages.insert(s) }
            weaknesses.formUnion((card.detail?.weaknesses ?? []).map(\.type))
            if let r = card.rarity, !r.isEmpty { rarities.insert(r) }
        }
        return Options(types: types.sorted(),
                       stages: stages.sorted { stageOrder($0) < stageOrder($1) },
                       weaknesses: weaknesses.sorted(),
                       rarities: rarities.sorted { (TinSorting.rarityRank($0), $0) < (TinSorting.rarityRank($1), $1) })
    }

    /// Evolution order, then the mechanics, then the non-Pokémon — not alphabetical, which would
    /// put "Stage 2" after "BREAK" and "Basic" in the middle.
    private static func stageOrder(_ s: String) -> (Int, String) {
        switch s {
        case "Basic": return (0, s)
        case "Stage 1": return (1, s)
        case "Stage 2": return (2, s)
        case "Trainer": return (8, s)
        case "Energy": return (9, s)
        default: return (5, s)
        }
    }
}

enum TinSorting {
    /// - Parameters:
    ///   - card: the catalog record for an entry's card (cached by the caller).
    ///   - setDate: a set's release date, "yyyy-MM-dd" (sorts lexicographically).
    ///   - value: the entry's current value, the same figure its row shows.
    static func sorted(_ entries: [CollectionEntry], by sort: TinSort,
                       card: (String) -> CardRecord?, setDate: (String) -> String?,
                       value: (CollectionEntry) -> Double?) -> [CollectionEntry] {
        func name(_ e: CollectionEntry) -> String { card(e.cardId)?.name ?? e.cardId }
        func byName(_ a: CollectionEntry, _ b: CollectionEntry) -> Bool {
            let order = name(a).localizedStandardCompare(name(b))
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        /// Set release date, then printed number ("2" < "10" < "TG20"); undated sets last.
        func collectorOrder(_ a: CollectionEntry, _ b: CollectionEntry, newestFirst: Bool) -> Bool {
            let (ca, cb) = (card(a.cardId), card(b.cardId))
            let (da, db) = (ca.flatMap { setDate($0.setId) }, cb.flatMap { setDate($0.setId) })
            if da != db {
                guard let da else { return false }
                guard let db else { return true }
                return newestFirst ? da > db : da < db
            }
            if ca?.setId != cb?.setId { return (ca?.setId ?? "") < (cb?.setId ?? "") }
            let order = (ca?.number ?? "").localizedStandardCompare(cb?.number ?? "")
            return order == .orderedSame ? byName(a, b) : order == .orderedAscending
        }

        switch sort {
        case .newest:
            return entries.sorted { $0.addedAt == $1.addedAt ? $0.id < $1.id : $0.addedAt > $1.addedAt }
        case .value:
            // Precomputed: the comparator runs n log n times and a value walks a price ladder.
            let values = Dictionary(entries.map { ($0.id, value($0) ?? -1) }, uniquingKeysWith: { a, _ in a })
            return entries.sorted { (values[$0.id] ?? -1, $1.id) > (values[$1.id] ?? -1, $0.id) }
        case .name:
            return entries.sorted(by: byName)
        case .setOldest:
            return entries.sorted { collectorOrder($0, $1, newestFirst: false) }
        case .setNewest:
            return entries.sorted { collectorOrder($0, $1, newestFirst: true) }
        case .rarity:
            return entries.sorted {
                let (ra, rb) = (rarityRank(card($0.cardId)?.rarity), rarityRank(card($1.cardId)?.rarity))
                return ra == rb ? byName($0, $1) : ra > rb
            }
        case .hp:
            // Trainers and Energy have no HP; they sink rather than reading as "0 HP".
            return entries.sorted {
                let (ha, hb) = (card($0.cardId)?.hp ?? -1, card($1.cardId)?.hp ?? -1)
                return ha == hb ? byName($0, $1) : ha > hb
            }
        }
    }

    /// Commonest 1 → rarest 10. The catalog's rarity strings span 28 years of naming ("Rare Holo",
    /// "Double rare", "Special illustration rare"), so this ranks by keyword, most specific first,
    /// and anything unrecognised that still says "rare" sits with plain Rare.
    /// ponytail: a keyword ladder, not a table of every string — add a rung when a new era names
    /// something this misplaces.
    static func rarityRank(_ rarity: String?) -> Int {
        let r = rarity?.lowercased() ?? ""
        let ladder: [(String, Int)] = [
            ("special illustration", 9), ("hyper", 10), ("secret", 10), ("rainbow", 10),
            ("shiny ultra", 8), ("ultra", 8), ("illustration", 7), ("full art", 7),
            ("shiny", 6), ("double", 6), ("ace spec", 6), ("radiant", 6), ("amazing", 6),
            ("prime", 6), ("legend", 6), ("break", 6), ("vmax", 6), ("vstar", 6),
            ("holo ex", 6), ("holo gx", 6), ("holo v", 6), ("holo", 5),
            ("promo", 3), ("uncommon", 2), ("common", 1), ("rare", 4),
        ]
        return ladder.first { r.contains($0.0) }?.1 ?? 0
    }
}
