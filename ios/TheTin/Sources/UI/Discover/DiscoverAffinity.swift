import Foundation

/// Pure, deterministic recommendation logic for the Discover "For You" row.
/// No SwiftUI, no Firestore, no CatalogStore — operates on plain records.
enum DiscoverAffinity {
    static let ownedWeight = 1.0
    static let wantedWeight = 2.0

    /// How loudly a wishlist card speaks, by priority.
    ///
    /// A grail and a shrug used to weigh the same — every wanted card accumulated a flat
    /// `wantedWeight`, so `WantPriority` was recorded and never read.
    ///
    /// ⚠️ `.normal` is deliberately **equal to `wantedWeight`**, not lower. Rebasing the scale so
    /// Normal keeps today's value means a wishlist with no priorities set ranks exactly as it
    /// always has; only a user who actually set a priority sees a change.
    static func weight(for priority: WantPriority) -> Double {
        switch priority {
        case .grail:  return 3.0
        case .high:   return 2.5
        case .normal: return 2.0
        case .low:    return 1.0
        }
    }

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
    /// `priorities` maps a wanted card's id to its `WantPriority`. An id missing from the map is
    /// treated as `.normal` — the same lenient default `WantPriority`'s decoder uses.
    static func profile(owned: [CardRecord], wanted: [CardRecord], dexIds: [String: [Int]],
                        priorities: [String: WantPriority] = [:]) -> Profile {
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
        for card in wanted {
            accumulate([card], weight(for: priorities[card.id] ?? .normal))
        }

        return Profile(sets: normalize(sets), species: normalize(species),
                       artists: normalize(artists), rarities: normalize(rarities), types: normalize(types))
    }

    /// How far either side of a liked species counts as "the same family".
    ///
    /// ⚠️ A heuristic, and a knowingly imperfect one. Evolution families occupy contiguous dex ids
    /// (Charmander 4 → Charmeleon 5 → Charizard 6), so a radius of 2 covers a three-stage family
    /// from either end — but it is wrong for Eeveelutions and for cross-generation evolutions, and
    /// it will occasionally pull in an unrelated neighbour. Accepted because it costs nothing; the
    /// upgrade, if it misfires visibly, is TCGdex's `evolveFrom` as a real evolution table.
    static let adjacencyRadius = 2
    static let adjacencyWeight = 0.6
    static let coOccurrenceWeight = 0.5

    /// Expand the profile's species histogram into a wider "and things like these" map.
    ///
    /// `seed` is `Profile.species`; `coOccurring` comes from `CatalogStore.coOccurringDexIds(with:)`
    /// and is passed in rather than fetched so this stays pure and testable.
    ///
    /// Derived weights scale with the seed that produced them — a species you barely like does not
    /// promote its whole family as hard as one you love. Where two routes reach the same dex id the
    /// **strongest wins**, so an exact match is never downgraded by a weaker derived route.
    static func relatedSpecies(seed: [Int: Double], coOccurring: Set<Int>) -> [Int: Double] {
        guard !seed.isEmpty else { return [:] }
        var out = seed
        func offer(_ dexId: Int, _ weight: Double) {
            guard dexId > 0 else { return }
            out[dexId] = max(out[dexId] ?? 0, weight)
        }
        for (dexId, weight) in seed {
            for offset in 1...adjacencyRadius {
                offer(dexId - offset, weight * adjacencyWeight)
                offer(dexId + offset, weight * adjacencyWeight)
            }
        }
        let strongestSeed = seed.values.max() ?? 0
        for dexId in coOccurring { offer(dexId, strongestSeed * coOccurrenceWeight) }
        return out
    }

    /// Bucket slots reserved for species the expansion ADDED, on top of the exact-match slots.
    ///
    /// ⚠️ Without this the expansion is invisible. Adjacency caps at 0.6x its seed, so any user with
    /// four or more exact species at >= 0.6 fills the whole cut with exact matches and no derived
    /// species is ever pulled into the candidate pool. Measured on a real 60-card collection: 79
    /// species widened to 267, and the first derived entry landed at **rank 6** against a cut of 4.
    static let derivedBucketSlots = 3

    /// The species buckets a page should pull candidates from: the strongest exact matches, plus a
    /// reserved tail of the strongest species the expansion added. Ordered exact-first, so the
    /// user's own collection still leads.
    static func speciesBuckets(exact: [Int: Double], related: [Int: Double], depth: Int) -> [Int] {
        guard !exact.isEmpty else { return [] }
        let topExact = exact.sorted { $0.value > $1.value }.prefix(depth).map(\.key)
        let derived = related
            .filter { exact[$0.key] == nil }
            .sorted { $0.value > $1.value }
            .prefix(derivedBucketSlots)
            .map(\.key)
        return topExact + derived
    }

    private static func normalize<K>(_ hist: [K: Double]) -> [K: Double] {
        guard let maxValue = hist.values.max(), maxValue > 0 else { return [:] }
        return hist.mapValues { $0 / maxValue }
    }

    /// Added to the score of a card whose art is an identical-art reprint of something on the
    /// wishlist. `card_twin` was built for the scanner's twin-aware lock and is free to reuse here:
    /// "you want this exact art, and here it is cheaper from another print".
    static let twinBoost = 0.9

    /// How much more a species match counts than any other single dimension.
    ///
    /// ⚠️ `score` used to sum all five dimensions flat, and that quietly made species the weakest
    /// signal in the system: set + artist + rarity + type can contribute ~4 points, against
    /// species' maximum of 1. So "a Pokemon you like" could never outrank "same set, same artist",
    /// and For You kept returning the same cluster however well the species expansion worked.
    ///
    /// Species is the axis users actually think in — "show me more Charizards", not "show me more
    /// cards illustrated by the person who drew my Charizard". Weighted 3x, a liked species beats a
    /// liked set AND a liked artist together; set/artist/rarity/type become the tiebreak they
    /// should always have been.
    static let speciesWeight = 3.0

    /// Sum of normalized profile weights across a candidate's dimensions, plus a twin boost, all
    /// scaled by how well the price fits the user's band.
    ///
    /// The band is a **multiplier and never a filter** — see `PriceBand.fit`. An absent band or an
    /// absent price is neutral.
    static func score(_ card: CardRecord, dexIds: [Int], profile: Profile,
                      band: PriceBand? = nil, priceUsd: Double? = nil,
                      twinOfWanted: Bool = false) -> Double {
        var s = profile.sets[card.setId] ?? 0
        if let a = card.artist { s += profile.artists[a] ?? 0 }
        if let r = card.rarity { s += profile.rarities[r] ?? 0 }
        for t in card.types { s += profile.types[t] ?? 0 }
        for d in dexIds { s += (profile.species[d] ?? 0) * speciesWeight }
        if twinOfWanted { s += twinBoost }
        return s * (band?.fit(priceUsd) ?? 1.0)
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
                     band: PriceBand? = nil, prices: [String: Double] = [:],
                     twinIds: Set<String> = [], perGroupCap: Int = 3, limit: Int = 30) -> [CardRecord] {
        var scored: [ScoredCard] = []
        for candidate in candidates {
            let candidateDexIds: [Int] = dexIds[candidate.id] ?? []
            let candidateScore: Double = score(candidate, dexIds: candidateDexIds, profile: profile,
                                               band: band, priceUsd: prices[candidate.id],
                                               twinOfWanted: twinIds.contains(candidate.id))
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
