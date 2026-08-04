import Foundation

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

    /// How far a band-fit multiplier can fall. Deliberately well above zero: price alone must never
    /// fully suppress a card, or For You goes blind to the user's grail — the one card whose price
    /// they most want to see move.
    static let fitFloor = 0.35

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
    static func make(entries: [CollectionEntry], wants: [String: WantEntry], now: Date) -> PriceBand? {
        let cutoff = now.addingTimeInterval(-Double(purchaseWindowMonths) * 30.4 * 86_400)
        let purchases: [Double] = entries.compactMap { entry in
            guard !entry.isSold, let paid = entry.pricePaid else { return nil }
            if let acquired = entry.acquiredAt, acquired < cutoff { return nil }
            return paid
        }
        if let fromPurchases = make(purchases: purchases, targets: []) { return fromPurchases }
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
