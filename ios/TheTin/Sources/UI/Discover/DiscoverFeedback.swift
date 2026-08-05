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

    /// How long a stated reason keeps half its force. Taste drifts: a rejection from three months
    /// ago is weaker evidence about what you want today than one from this morning.
    static let halfLifeDays = 60.0

    /// How many live "too expensive" statements a ceiling needs before it bites.
    ///
    /// ⚠️ The ceiling used to be `min()` over every such price, set by a single tap and never
    /// surfaced or reversible. Measured against a real collection: one tap on a $5.20 card
    /// permanently removed **66% of the deck**, and that user's band `p25` was $5.13 — a ceiling any
    /// lower empties For You entirely. This became genuinely dangerous the moment `varietyPicks` was
    /// fixed: before, taps landed on $4,000 grails and the ceiling was harmlessly out of range;
    /// now every card shown is in-band, so every tap lands where the blast radius is worst.
    static let minimumCeilingEvents = 2

    /// Below this an event no longer counts toward the ceiling at all. Equal to one half-life.
    static let ceilingLiveWeight = 0.5

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
        var ceilingPrices: [Double] = []

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
            case .tooExpensive:
                // ⚠️ The ceiling does NOT decay in VALUE — a $30 ceiling drifting to $1,920 after
                // six half-lives is nonsense. Events expire OUT of it instead, which composes with
                // corroboration for free: an old lone tap simply stops counting.
                if let price = prices[cardId], price > 0, w >= ceilingLiveWeight {
                    ceilingPrices.append(price)
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

        // The ceiling is the **second-cheapest** thing the user called too expensive.
        //
        // ⚠️ Not `min()`, and not a percentile either. `min()` lets one mistap on a cheap card set a
        // permanent cut (measured: a $5.20 tap removed 66% of a real deck). A percentile does not
        // help: nearest-rank p25 over four samples IS the minimum — it only starts skipping the
        // lowest at n ≥ 5 — so p25 would obey exactly the mistap it was meant to absorb.
        //
        // Second-cheapest states something true and checkable: *at least two cards you rejected are
        // priced at or above this*. A lone stray tap cannot set it, and a stray tap alongside a
        // genuine rejection is discarded rather than obeyed — reject $200, mistap $6, and the
        // ceiling is $200, not $6.
        //
        // It errs deliberately toward leniency. A ceiling that is too high shows a few cards the
        // user did not want; one that is too low empties the whole feature silently.
        if ceilingPrices.count >= minimumCeilingEvents {
            out.priceCeiling = ceilingPrices.sorted()[minimumCeilingEvents - 1]
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
    ///
    /// ⚠️ This alone is NOT enough, and assuming it was is the reason `excludes(price:)` exists —
    /// see there.
    func apply(to band: PriceBand?) -> PriceBand? {
        guard let band else { return nil }
        guard let ceiling = priceCeiling, ceiling < band.p75 else { return band }
        return PriceBand(p25: min(band.p25, ceiling),
                         p50: min(band.p50, ceiling),
                         p75: ceiling)
    }

    /// Is this price at or above the cheapest thing the user called too expensive?
    ///
    /// ⚠️ **"Too expensive" has to be a hard cut, not a band nudge.** Measured against a real
    /// collection: that user's band was $5.13–$33.55, while the cards they were actually rejecting
    /// were $80–$352. Every one of those is ALREADY above `p75`, so `apply(to:band)` changed
    /// nothing — and they were already pinned at the 0.15 price floor yet still ranked top, because
    /// a 3x species match swamps any multiplier. Tapping "Too expensive" would have felt like it
    /// did nothing, which is exactly the failure this whole branch already made once.
    ///
    /// So the ceiling excludes outright. It only ever comes from an explicit statement about a
    /// specific price, and it is undone by restoring that card — `restore` drops the reason, which
    /// re-derives the ceiling from what's left.
    func excludes(price: Double?) -> Bool {
        guard let ceiling = priceCeiling, let price else { return false }
        return price >= ceiling
    }
}
