import Foundation

/// Pure, deterministic recommendation logic for the Discover "For You" row.
/// No SwiftUI, no Firestore, no CatalogStore — operates on plain records.
enum DiscoverAffinity {
    static let ownedWeight = 1.0
    static let wantedWeight = 2.0

    /// Normalized taste weights per dimension (each value in 0...1), from the user's cards.
    struct Profile: Equatable {
        var sets: [String: Double] = [:]
        var species: [Int: Double] = [:]
        var artists: [String: Double] = [:]
        var rarities: [String: Double] = [:]
        var types: [String: Double] = [:]
        var isEmpty: Bool {
            sets.isEmpty && species.isEmpty && artists.isEmpty && rarities.isEmpty && types.isEmpty
        }
    }

    /// Build normalized affinity histograms. `dexIds` maps card id → its species dex ids.
    /// Wanted cards weight higher than owned (active intent). Each dimension is normalized by
    /// its own max so no single dimension dominates purely by raw count.
    static func profile(owned: [CardRecord], wanted: [CardRecord], dexIds: [String: [Int]]) -> Profile {
        var sets: [String: Double] = [:]
        var species: [Int: Double] = [:]
        var artists: [String: Double] = [:]
        var rarities: [String: Double] = [:]
        var types: [String: Double] = [:]

        func accumulate(_ cards: [CardRecord], _ weight: Double) {
            for c in cards {
                sets[c.setId, default: 0] += weight
                if let a = c.artist { artists[a, default: 0] += weight }
                if let r = c.rarity { rarities[r, default: 0] += weight }
                for t in c.types { types[t, default: 0] += weight }
                for d in dexIds[c.id] ?? [] { species[d, default: 0] += weight }
            }
        }
        accumulate(owned, ownedWeight)
        accumulate(wanted, wantedWeight)

        return Profile(sets: normalize(sets), species: normalize(species),
                       artists: normalize(artists), rarities: normalize(rarities), types: normalize(types))
    }

    private static func normalize<K>(_ hist: [K: Double]) -> [K: Double] {
        guard let maxValue = hist.values.max(), maxValue > 0 else { return [:] }
        return hist.mapValues { $0 / maxValue }
    }

    /// Sum of normalized profile weights across a candidate's dimensions.
    static func score(_ card: CardRecord, dexIds: [Int], profile: Profile) -> Double {
        var s = profile.sets[card.setId] ?? 0
        if let a = card.artist { s += profile.artists[a] ?? 0 }
        if let r = card.rarity { s += profile.rarities[r] ?? 0 }
        for t in card.types { s += profile.types[t] ?? 0 }
        for d in dexIds { s += profile.species[d] ?? 0 }
        return s
    }

    /// A candidate paired with its computed affinity score.
    private struct ScoredCard {
        let card: CardRecord
        let score: Double
    }

    /// Rank candidates by score desc (stable tiebreak by id), drop zero-score, apply per-set,
    /// per-species, and per-artist diversity caps, take `limit`. The per-artist cap stops one
    /// prolific favorite illustrator from flooding the ranking (long "More from X" runs).
    static func rank(candidates: [CardRecord], dexIds: [String: [Int]], profile: Profile,
                     perGroupCap: Int = 3, limit: Int = 30) -> [CardRecord] {
        var scored: [ScoredCard] = []
        for candidate in candidates {
            let candidateDexIds: [Int] = dexIds[candidate.id] ?? []
            let candidateScore: Double = score(candidate, dexIds: candidateDexIds, profile: profile)
            if candidateScore > 0 {
                scored.append(ScoredCard(card: candidate, score: candidateScore))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.card.id < rhs.card.id
        }

        var setCounts: [String: Int] = [:]
        var speciesCounts: [Int: Int] = [:]
        var artistCounts: [String: Int] = [:]
        var out: [CardRecord] = []
        for entry in scored {
            let card = entry.card
            if setCounts[card.setId, default: 0] >= perGroupCap { continue }
            if let a = card.artist, artistCounts[a, default: 0] >= perGroupCap { continue }
            let ds = dexIds[card.id] ?? []
            if ds.contains(where: { speciesCounts[$0, default: 0] >= perGroupCap }) { continue }
            out.append(card)
            setCounts[card.setId, default: 0] += 1
            if let a = card.artist { artistCounts[a, default: 0] += 1 }
            for d in ds { speciesCounts[d, default: 0] += 1 }
            if out.count >= limit { break }
        }
        return out
    }

    /// The "why" caption shown under a For You card, in priority order. Full-art wins (product
    /// choice): a SIR/IR reads "Full-art find" even when it also matches a liked species/artist.
    /// Otherwise: liked species → liked artist → liked set → chase price → cheaper/pricier vs the
    /// user's typical spend → a generic "something new". Pure/deterministic; `speciesNames` maps the
    /// card's dex ids to display names, `referencePrice` is the user's average taste-card price.
    static func forYouReason(card: CardRecord, cardDexIds: [Int], speciesNames: [Int: String],
                             profile: Profile, priceUsd: Double?, referencePrice: Double?,
                             chaseThreshold: Double = 50,
                             fullArtRarities: Set<String> = DiscoverConstants.fullArtRarities) -> String {
        if let r = card.rarity, fullArtRarities.contains(r) { return "✨ Full-art find" }
        let likedDex: Int? = cardDexIds
            .filter { (profile.species[$0] ?? 0) > 0 }
            .max { (profile.species[$0] ?? 0) < (profile.species[$1] ?? 0) }
        if let d = likedDex, let name = speciesNames[d] { return "Because you like \(name)" }
        if let a = card.artist, (profile.artists[a] ?? 0) > 0 { return "More from \(a)" }
        if (profile.sets[card.setId] ?? 0) > 0 { return "From a set you like" }
        if let p = priceUsd {
            if p >= chaseThreshold { return "🔥 Chase pick · $\(Int(p))" }
            if let ref = referencePrice, ref > 0 {
                if p <= ref * 0.7 { return "Cheaper pick" }
                if p >= ref * 1.3 { return "A little pricier" }
            }
        }
        return "Something new to try"
    }
}
