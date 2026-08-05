import Foundation

/// Turns stated dismissal reasons into concrete adjustments to the taste profile and the price
/// band. Pure and deterministic — no catalog, no I/O; the caller resolves the dismissed cards.
///
/// The design constraint that makes this worth having: **each reason moves exactly one dimension.**
/// "Too expensive" tightens the band and nothing else. That keeps "why am I seeing this" answerable,
/// and it means a wrong answer from the user degrades one axis rather than poisoning the whole
/// profile.
struct DiscoverFeedback: Equatable, Sendable {
    /// Multiplier applied to `Profile.species[dexId]`.
    var species: [Int: Double] = [:]
    /// Multiplier applied to `Profile.generations[gen]`.
    var generations: [Int: Double] = [:]
    /// Multiplier applied to `Profile.rarities[rarity]`.
    var rarities: [String: Double] = [:]
    /// The cheapest card ever called "too expensive". Everything at or above it is priced out.
    var priceCeiling: Double?

    /// How hard one "no" hits the dimension it names. Compounds: two rejections of the same species
    /// leave it at 0.25.
    static let penalty = 0.5
    /// Compounding stops here. A dimension the user has rejected five times is not evidence they
    /// want it *never* — they may still own cards there, and zeroing it would make an owned species
    /// invisible in its own recommendations.
    static let minimumMultiplier = 0.05

    /// Derive adjustments from the rejected cards and what the user said about them.
    ///
    /// `cards` and `dexIds` cover only the cards that carry a reason — the caller does not need to
    /// resolve plain hides, which tune nothing.
    static func derive(reasons: [String: DismissReason],
                       cards: [String: CardRecord],
                       dexIds: [String: [Int]],
                       prices: [String: Double]) -> DiscoverFeedback {
        var out = DiscoverFeedback()
        func compound(_ current: Double?) -> Double {
            max((current ?? 1.0) * penalty, minimumMultiplier)
        }
        for (cardId, reason) in reasons.sorted(by: { $0.key < $1.key }) {
            guard let card = cards[cardId] else { continue }
            switch reason {
            case .tooExpensive:
                // The cheapest rejection wins: saying "$400 is too much" after "$90 is too much"
                // must not RAISE the ceiling back to $400.
                if let price = prices[cardId], price > 0 {
                    out.priceCeiling = min(out.priceCeiling ?? price, price)
                }
            case .notMySpecies:
                for dex in dexIds[cardId] ?? [] {
                    out.species[dex] = compound(out.species[dex])
                }
            case .wrongEra:
                for dex in dexIds[cardId] ?? [] {
                    guard let gen = PokemonRegion.all.first(where: { dex >= $0.lo && dex <= $0.hi })?.gen
                    else { continue }
                    out.generations[gen] = compound(out.generations[gen])
                }
            case .notMyKind:
                if let rarity = card.rarity {
                    out.rarities[rarity] = compound(out.rarities[rarity])
                }
            }
        }
        return out
    }

    /// Apply the multipliers to a freshly-built profile.
    ///
    /// ⚠️ Applied AFTER normalization, deliberately. Re-normalizing afterwards would undo the whole
    /// point: if the user rejects their top species, dividing by the new maximum would just promote
    /// something else to 1.0 and leave the relative ordering — and the score — unchanged.
    func apply(to profile: DiscoverAffinity.Profile) -> DiscoverAffinity.Profile {
        var out = profile
        for (dex, multiplier) in species where out.species[dex] != nil {
            out.species[dex]? *= multiplier
        }
        for (gen, multiplier) in generations where out.generations[gen] != nil {
            out.generations[gen]? *= multiplier
        }
        for (rarity, multiplier) in rarities where out.rarities[rarity] != nil {
            out.rarities[rarity]? *= multiplier
        }
        return out
    }

    /// Pull the band's top down under the cheapest "too expensive" rejection.
    ///
    /// Never inverts the band: a ceiling below `p25` collapses it to a point at the ceiling rather
    /// than producing `p75 < p25`, which would make `fit`'s width negative.
    func apply(to band: PriceBand?) -> PriceBand? {
        guard let band else { return nil }
        guard let ceiling = priceCeiling, ceiling < band.p75 else { return band }
        return PriceBand(p25: min(band.p25, ceiling),
                         p50: min(band.p50, ceiling),
                         p75: ceiling)
    }
}
