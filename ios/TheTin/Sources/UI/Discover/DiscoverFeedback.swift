import Foundation

/// Turns stated dismissal reasons into adjustments to the taste profile. Pure and deterministic —
/// no catalog, no I/O; the caller resolves the dismissed cards.
///
/// **Each reason moves at most one dimension**, which keeps "why am I seeing this" answerable and
/// means a wrong answer degrades one axis rather than poisoning the profile.
///
/// ⚠️ **Price is no longer one of those dimensions.** `tooExpensive` and the whole corroborated
/// price-ceiling mechanism were deleted: they were a second, *invisible* price control competing
/// with `PriceTiers`, which states the same thing visibly and is editable from Settings. Capping now
/// happens in `ShelfBuilder`, once, where every shelf passes.
///
struct DiscoverFeedback: Equatable, Sendable {
    /// Multiplier applied to `Profile.species[dexId]`.
    var species: [Int: Double] = [:]
    /// Multiplier applied to `Profile.generations[gen]`.
    var generations: [Int: Double] = [:]
    /// Multiplier applied to `Profile.rarities[rarity]`.
    var rarities: [String: Double] = [:]

    /// How hard one "no" hits the dimension it names. Compounds: two rejections of the same species
    /// leave it at 0.25.
    static let penalty = 0.5
    /// Compounding stops here. A dimension the user has rejected five times is not evidence they
    /// want it *never* — they may still own cards there, and zeroing it would make an owned species
    /// invisible in its own recommendations.
    static let minimumMultiplier = 0.05

    /// How long a stated reason keeps half its force. Taste drifts: a rejection from three months
    /// ago is weaker evidence about what you want today than one from this morning.
    static let halfLifeDays = 60.0

    /// An event's remaining force: `0.5 ^ (age / halfLife)`.
    ///
    /// A future-dated stamp — a clock change, a restored backup — is full strength, never amplified.
    static func weight(age: TimeInterval) -> Double {
        guard age > 0 else { return 1.0 }
        return pow(0.5, age / (halfLifeDays * 86_400))
    }

    /// Derive adjustments from the rejected cards, what the user said, and when they said it.
    ///
    /// `cards` and `dexIds` cover only the cards that carry a reason — the caller does not need to
    /// resolve plain hides, which tune nothing. An id missing from `at` is full strength; see
    /// `DiscoverSignalsData.at`.
    static func derive(reasons: [String: DismissReason],
                       at: [String: Date] = [:],
                       cards: [String: CardRecord],
                       dexIds: [String: [Int]],
                       prices: [String: Double],
                       now: Date = Date()) -> DiscoverFeedback {
        var out = DiscoverFeedback()

        for (cardId, reason) in reasons.sorted(by: { $0.key < $1.key }) {
            guard let card = cards[cardId] else { continue }
            let w = at[cardId].map { weight(age: now.timeIntervalSince($0)) } ?? 1.0
            // `penalty ^ w` rises toward 1.0 as the event fades, so a decayed penalty is a WEAKER
            // multiplier and never a stronger one.
            let decayed = pow(penalty, w)
            func compound(_ current: Double?) -> Double {
                max((current ?? 1.0) * decayed, minimumMultiplier)
            }
            switch reason {
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
            case .dontLikeArt, .notWorthThisPrice:
                // ⚠️ Deliberately tunes NOTHING. "Maybe I just don't like that art by that artist
                // but I like other art by that artist" — an artist penalty would be wrong and a
                // rarity one would be guessing. The card is hidden by `dismissed`; the reason is
                // recorded with a timestamp so a later version can learn from the accumulated
                // history without re-teaching. That is what raw-event storage was for.
                break
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
}
