import Foundation

/// The two lines a collector draws through the catalog, and the three intentions they create.
///
/// ⚠️ **This replaces a single `PriceBand` seed, and the change is a change of purpose.** A band
/// treats price as a way of SUPPRESSING cards — everything outside it is demoted. That is wrong:
///
/// > "for more than that I would have to really think about it and budget for it and talk to my
/// > wife, **but it's still fun to look at them**"
///
/// Expensive cards are not noise, they are a different *intention*. Price sorts cards into moods.
///
/// ⚠️ **Two thresholds, not three ranges.** Stated as ranges ("$1–10", "$30–60") a $20 card belongs
/// to no tier and the app has to guess silently. Thresholds partition the catalog with nothing
/// falling through.
struct PriceTiers: Equatable, Sendable, Codable {
    /// "I'd buy one without thinking, up to…"
    var routineCeiling: Double
    /// "Now and then, I'd go up to…" — and above this is Someday.
    var occasionalCeiling: Double

    static let choicesRoutine: [Double] = [5, 10, 25, 50]
    static let choicesOccasional: [Double] = [30, 60, 150, 500]
    static let `default` = PriceTiers(routineCeiling: 10, occasionalCeiling: 60)

    /// Which intention a price falls under. An unpriced card is `routine`: it is not a daydream,
    /// we simply do not know, and hiding it in Someday would be a claim we cannot support.
    func tier(for price: Double?) -> Tier {
        guard let price else { return .routine }
        if price <= routineCeiling { return .routine }
        if price <= occasionalCeiling { return .occasional }
        return .someday
    }

    enum Tier: String, Sendable { case routine, occasional, someday }

    /// The cap every buying row shares. `someday` is the only shelf allowed above it, which is what
    /// stops expensive cards leaking into rows that claim to be shopping lists.
    var buyingCeiling: Double { occasionalCeiling }

    /// Guards a hand-edited or restored value: the occasional line must sit above the routine one.
    /// The band these tiers imply — spanning the whole buying range, since the tiers themselves do
    /// the splitting into rows. Used for candidate selection and for affinity scoring.
    var band: PriceBand {
        PriceBand(p25: max(routineCeiling / 2, 0.01), p50: routineCeiling, p75: occasionalCeiling)
    }

    var normalized: PriceTiers {
        PriceTiers(routineCeiling: max(routineCeiling, 0.01),
                   occasionalCeiling: max(occasionalCeiling, max(routineCeiling, 0.01) + 0.01))
    }
}

/// The price range the user actually buys in, derived from what they have paid and what they have
/// said they would pay. Pure and deterministic — no catalog, no I/O.
///
/// This exists because `DiscoverModel.referencePrice` (the average market value of the user's taste
/// cards) answers the wrong question: it is inflated by every chase card they own and will never buy
/// again, and it was only ever used to write a caption. A band built from `pricePaid` and
/// `WantEntry.targetUsd` is a statement about *purchasing*, and it feeds the ranker.
struct PriceBand: Equatable {
    let p25: Double
    let p50: Double
    let p75: Double

    /// Below this many samples the band is noise, not a preference.
    static let minimumSamples = 3

    /// `targetUsd` is an explicit budget the user typed for a specific card; `pricePaid` is
    /// inferred from history. Counting a target twice lets an explicit statement dominate without
    /// discarding history entirely.
    static let targetWeight = 2

    /// How far a band-fit multiplier can fall. Kept in step with `DiscoverAffinity.dimensionFloor`
    /// so price, rarity and generation all demote by the same amount.
    ///
    /// ⚠️ This was `0.35`, on the stated reasoning that "price alone must never fully suppress a
    /// card, or For You goes blind to the user's grail". **That reasoning was wrong**:
    /// `ForYouStream` already removes every owned and wanted card from the candidate pool, so a
    /// grail is never a For You candidate and the floor was protecting nothing. What 0.35 actually
    /// did was let a $1,000 card ride a 3x species match past an in-band one.
    static let fitFloor = 0.15

    /// Nearest-rank percentile over a **pre-sorted, non-empty** sample.
    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        let rank = Int((q * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    /// Build the band, or `nil` when there is not enough signal to have one. Non-positive amounts
    /// are dropped: a zero or negative `pricePaid` is a data-entry artifact, not a free card.
    static func make(purchases: [Double], targets: [Double]) -> PriceBand? {
        var sample = purchases.filter { $0 > 0 }
        for target in targets where target > 0 {
            for _ in 0..<targetWeight { sample.append(target) }
        }
        guard sample.count >= minimumSamples else { return nil }
        sample.sort()
        return PriceBand(p25: percentile(sample, 0.25),
                         p50: percentile(sample, 0.50),
                         p75: percentile(sample, 0.75))
    }

    /// Purchases older than this stop describing what the user buys today.
    static let purchaseWindowMonths = 24

    /// Build the band from the user's own records.
    ///
    /// Sold copies are excluded — what you offloaded is not evidence of what you buy. An entry with
    /// **no `acquiredAt` still counts**: `pricePaid` is the signal, and a missing date is an
    /// unrecorded detail rather than proof the purchase is stale. (The spec said "entries with
    /// `acquiredAt` within 24 months"; discarding every undated purchase would throw away most of a
    /// typical collection, so undated entries are kept.)
    /// ⚠️ **Targets are a FALLBACK, not an ingredient.** They used to be folded into the same
    /// sample (counted twice, so an "explicit budget dominates"), and on real data that was a
    /// measured disaster: six purchases at $5–66 plus three wishlist targets at $90–250 gave a band
    /// of **$6.24–$200**, which made `fit()` return 1.0 for virtually the entire catalog. The band
    /// multiplier did nothing at all.
    ///
    /// The reasoning was wrong, not just the arithmetic. A `targetUsd` is the ceiling the user set
    /// for ONE specific expensive card — it says nothing about typical spend, and averaging it with
    /// purchase history merges two different distributions. Purchases alone give a real band (that
    /// same collection yields $5.13–$33.55). Targets carry the band only when there is no purchase
    /// history to build one from, where three aspirational numbers still beat nothing.
    ///
    /// Per-card targets are not lost — "$4 under your target" is a per-card caption, which is where
    /// that signal belongs.
    /// Precedence: **purchases → targets → the seeded budget → nil.**
    ///
    /// The seed is the last resort and it evaporates on its own — once three real purchases exist
    /// the first branch wins and the seed is never consulted again. Nothing to migrate, nothing to
    /// expire, no stale guess outliving the evidence that replaced it.
    static func make(entries: [CollectionEntry], wants: [String: WantEntry],
                     seed: PriceTiers? = nil, now: Date) -> PriceBand? {
        let cutoff = now.addingTimeInterval(-Double(purchaseWindowMonths) * 30.4 * 86_400)
        let purchases: [Double] = entries.compactMap { entry in
            guard !entry.isSold, let paid = entry.pricePaid else { return nil }
            if let acquired = entry.acquiredAt, acquired < cutoff { return nil }
            return paid
        }
        if let fromPurchases = make(purchases: purchases, targets: []) { return fromPurchases }
        // ⚠️ The STATED tiers outrank inferred targets, and getting this backwards broke six of
        // nine rows on a real device. That user had one priced purchase (below the 3 needed), so
        // the band fell through to two aspirational wishlist targets — $90 and $200 — producing a
        // band of $90–$200 while they had explicitly stated a $60 buying ceiling. Every candidate
        // the band returned was then thrown away by that cap, and Easy adds, Worth a think,
        // Cheapest in 6 months, Down this week, the species rows and Something new all vanished.
        //
        // This file's own reasoning already said why: a `targetUsd` is the ceiling set for ONE
        // specific expensive card and says nothing about typical spend. It must not outrank a
        // direct statement of what the collector spends.
        if let seed { return seed.band }
        // Last resort: aspirational targets, for someone with no purchases who has somehow never
        // been asked (a backup restored from before the picker existed).
        return make(purchases: purchases, targets: wants.values.compactMap(\.targetUsd))
    }

    /// Multiplier applied to an affinity score: 1.0 inside the band, falling off linearly to
    /// `fitFloor` over one band-width in each direction, never below it.
    ///
    /// A **soft multiplier, not a filter**, on purpose. A hard price filter is the intuitive design
    /// and it is wrong here: it hides the expensive cards the user is actively hunting.
    ///
    /// `nil` (an unpriced card) is neutral, not bad — it returns 1.0.
    func fit(_ price: Double?, floor: Double = PriceBand.fitFloor) -> Double {
        guard let price else { return 1.0 }
        if price >= p25 && price <= p75 { return 1.0 }
        // Guard a degenerate zero-width band (every sample identical) against a divide by zero.
        let width = max(p75 - p25, 0.01)
        let distance = price < p25 ? p25 - price : price - p75
        let t = min(distance / width, 1.0)
        return 1.0 - t * (1.0 - floor)
    }
}
