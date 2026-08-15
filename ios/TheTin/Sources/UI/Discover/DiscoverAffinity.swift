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
        /// Which generations the collector actually lives in, rolled up from `species` via
        /// `PokemonRegion`. A much broader statement than species: it says "anything from Gen 1-5"
        /// for species the user has never owned, which no amount of per-species affinity can.
        var generations: [Int: Double] = [:]
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
        var generations: [Int: Double] = [:]

        func accumulate(_ cards: [CardRecord], _ weight: Double) {
            for c in cards {
                sets[c.setId, default: 0] += weight
                if let a = c.artist { artists[a, default: 0] += weight }
                if let r = c.rarity { rarities[r, default: 0] += weight }
                for t in c.types { types[t, default: 0] += weight }
                for d in dexIds[c.id] ?? [] {
                    species[d, default: 0] += weight
                    if let gen = PokemonRegion.all.first(where: { d >= $0.lo && d <= $0.hi })?.gen {
                        generations[gen, default: 0] += weight
                    }
                }
            }
        }
        accumulate(owned, ownedWeight)
        for card in wanted {
            accumulate([card], weight(for: priorities[card.id] ?? .normal))
        }

        return Profile(sets: normalize(sets), species: normalize(species),
                       artists: normalize(artists), rarities: normalize(rarities),
                       types: normalize(types), generations: normalize(generations))
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

    /// How far any multiplicative dimension can demote a card. Shared by price, rarity and
    /// generation so there is one story, not three.
    ///
    /// Not zero, because a profile is evidence and not a rule — a collector with no Gen 8 cards has
    /// not *forbidden* Gen 8. But low enough that three strikes (wrong price, wrong rarity, wrong
    /// generation) multiply to ~0.003 and the card is effectively gone.
    static let dimensionFloor = 0.15

    /// Map a normalized profile weight (0…1) onto a multiplier in `dimensionFloor`…1.
    /// An **empty** histogram is neutral: at cold start we know nothing, and demoting the entire
    /// catalog to the floor would be a statement we have no evidence for.
    private static func fit(_ weight: Double?, empty: Bool) -> Double {
        if empty { return 1.0 }
        return dimensionFloor + (1.0 - dimensionFloor) * (weight ?? 0)
    }

    /// How well a card's rarity matches what the collector actually buys.
    ///
    /// ⚠️ Rarity used to be an **attractor** — a flat `+= profile.rarities[r]`, capped at 1. So a
    /// Common scored `+0` and was never *penalised*; with species weighted 3x it could still win
    /// outright. "I only like full art" was unrepresentable in the old model, because no dimension
    /// could subtract.
    static func rarityFit(_ rarity: String?, profile: Profile) -> Double {
        fit(rarity.flatMap { profile.rarities[$0] }, empty: profile.rarities.isEmpty)
    }

    /// How well a card's generation matches where the collector lives, taking the card's **best**
    /// generation when it carries several species.
    ///
    /// A card with no dex id at all (trainers, energy) is neutral, not punished — it has no
    /// generation to be wrong about.
    static func generationFit(_ dexIds: [Int], profile: Profile) -> Double {
        guard !dexIds.isEmpty else { return 1.0 }
        let best = dexIds.compactMap { dex -> Double? in
            PokemonRegion.all.first { dex >= $0.lo && dex <= $0.hi }.map { profile.generations[$0.gen] ?? 0 }
        }.max()
        return fit(best, empty: profile.generations.isEmpty)
    }

    /// A card's rank score: **attractors** (reasons to show it) scaled by **filters** (reasons not
    /// to).
    ///
    /// That split is the model, and it is the thing the first cut of this got wrong. Set, artist and
    /// species are additive — each is a reason a card might interest you, and more reasons is
    /// better. Price, rarity and generation are multiplicative — they can only ever take away,
    /// because "$1,000", "Common" and "Gen 9" are how a collector says *no*. A purely additive score
    /// has no way to express dislike: the worst any dimension can do is contribute nothing, which
    /// loses to a single strong match somewhere else.
    static func score(_ card: CardRecord, dexIds: [Int], profile: Profile,
                      band: PriceBand? = nil, priceUsd: Double? = nil,
                      twinOfWanted: Bool = false) -> Double {
        var attractors = profile.sets[card.setId] ?? 0
        if let a = card.artist { attractors += profile.artists[a] ?? 0 }
        for t in card.types { attractors += profile.types[t] ?? 0 }
        for d in dexIds { attractors += (profile.species[d] ?? 0) * speciesWeight }
        if twinOfWanted { attractors += twinBoost }

        let filters = (band?.fit(priceUsd) ?? 1.0)
            * rarityFit(card.rarity, profile: profile)
            * generationFit(dexIds, profile: profile)
        return attractors * filters
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

}
