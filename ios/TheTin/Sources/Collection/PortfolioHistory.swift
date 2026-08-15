import Foundation

/// One weekly bucket of the portfolio series.
struct PortfolioPoint: Equatable {
    let date: Date
    /// What you HELD at this date, at that date's prices. Deliberately excludes anything already
    /// sold, so the last bucket still equals the tin header exactly.
    let value: Double
    /// What you'd paid for everything acquired by this date — including copies since sold, because
    /// the money was spent either way.
    let costBasis: Double
    /// Cash from copies sold by this date. Separate from `value` precisely so the chart can keep
    /// meaning "what I hold" while the comparison against `costBasis` can still be honest.
    /// Defaulted so existing constructions (and tests) compile unchanged.
    var realised: Double = 0
}

/// The series plus history coverage (UI: "based on X of Y cards" when < 100%).
struct PortfolioSeries: Equatable {
    let points: [PortfolioPoint]
    let cardsWithHistory: Int
    let totalCards: Int
}

/// Reconstructs the collection's value over time from per-card weekly `price_history`. Pure —
/// no I/O, no clock reads beyond the injected `now`.
///
/// **Sold copies stay in the series.** Pass them in and a sold card keeps its cost in the basis
/// forever (you did spend that money) and switches from market value to what you actually got for
/// it on the day it went. Drop them instead — which is what happened when `entries` became
/// sold-filtered — and both sides vanish together, so selling at a loss makes "Change vs. paid"
/// *improve*:
///
///     paid 170, worth 163, sold for 155  →  basis −170, value −163  →  the number went UP $7
///     on a $15 loss (measured on device, 2026-07-26)
///
/// The error is exactly the realised gain or loss, which is precisely the thing the number is
/// supposed to be reporting.
enum PortfolioHistory {
    private static let week: TimeInterval = 7 * 86_400

    /// `histories` values must be oldest-first (as `CatalogStore.priceHistory` returns them).
    /// The trailing defaulted `now:` exists for tests — the widget feature's pinned call shape
    /// compiles unchanged since new params are all defaulted.
    static func series(entries: [CollectionEntry],
                       histories: [String: [PricePoint]],
                       prices: [String: PriceRecord],
                       variantsByCard: [String: [VariantPrice]],
                       conditionsByCard: [String: [ConditionPrice]],
                       matrixByCard: [String: [MatrixPrice]] = [:],
                       gradedByPrintingByCard: [String: [GradedPrintingPrice]] = [:],
                       now: Date = Date()) -> PortfolioSeries {
        // Coverage describes the CHART's completeness, so it counts what you still own — a sold
        // card contributes a flat known number, never an interpolated one, so it can't be
        // "missing history".
        let cardIds = Set(entries.filter { !$0.isSold }.map(\.cardId))
        // Trimmed ONCE, up front, so coverage, `scale` and the bucket loop all agree on what is
        // actually plotted.
        let trusted = Dictionary(uniqueKeysWithValues: Set(entries.map(\.cardId)).map {
            ($0, trustedHistory(histories[$0] ?? []))
        })
        let covered = cardIds.filter { !(trusted[$0] ?? []).isEmpty }.count
        // Per-entry constants, hoisted out of the bucket loop.
        let ownedDates = entries.map { ownedFrom($0, now: now) }
        let scales = entries.map { scale($0, price: prices[$0.cardId],
                                         history: trusted[$0.cardId] ?? [],
                                         variants: variantsByCard[$0.cardId] ?? [],
                                         conditions: conditionsByCard[$0.cardId] ?? [],
                                         matrix: matrixByCard[$0.cardId] ?? [],
                                         gradedByPrinting: gradedByPrintingByCard[$0.cardId] ?? []) }
        // Current per-unit value (same math as the tin header's total). nil = no price data.
        let currentUnits = entries.map { e -> Double? in
            guard e.qty > 0,
                  let total = GroupStats.entryValue(e, price: prices[e.cardId],
                                                    variants: variantsByCard[e.cardId] ?? [],
                                                    conditions: conditionsByCard[e.cardId] ?? [],
                                                    matrix: matrixByCard[e.cardId] ?? [],
                                                    gradedByPrinting: gradedByPrintingByCard[e.cardId] ?? [])
            else { return nil }
            return total / Double(e.qty)
        }
        guard let earliest = ownedDates.min() else {
            return PortfolioSeries(points: [], cardsWithHistory: 0, totalCards: 0)
        }
        var dates: [Date] = []
        var d = earliest
        while d < now { dates.append(d); d += Self.week }
        dates.append(now)   // "now" is always the final bucket

        let points = dates.enumerated().map { (bucket, date) -> PortfolioPoint in
            var value = 0.0
            var basis = 0.0
            var realised = 0.0
            let isNow = bucket == dates.count - 1
            for (i, entry) in entries.enumerated() where ownedDates[i] <= date {
                basis += entry.pricePaid ?? 0   // per-entry TOTAL — never × qty (spec, resolved 2026-07-14)
                // Already sold by this bucket: it is no longer part of what you hold, so it adds
                // nothing to `value` — that's what keeps the headline equal to the tin total.
                // What you got for it lands in `realised` instead. `soldFor` is nil for a trade or
                // a gift: no cash came in, and whatever was received counts as its own entry.
                if let soldAt = entry.soldAt, soldAt <= date {
                    realised += entry.soldFor ?? 0
                    continue
                }
                let history = trusted[entry.cardId] ?? []
                // The "now" bucket prices at TODAY's prices — identical math to the tin header,
                // so the portfolio headline always agrees with it (weekly history lags the daily
                // price_latest). A card with no history holds flat at today's value across every
                // bucket — same no-fabricated-zeros principle as the late-history clamp below.
                if isNow || history.isEmpty, let unit = currentUnits[i] {
                    value += unit * Double(entry.qty)
                } else if let raw = rawPrice(history, at: date) {
                    value += raw * scales[i] * Double(entry.qty)
                }
            }
            return PortfolioPoint(date: date, value: value, costBasis: basis, realised: realised)
        }
        return PortfolioSeries(points: points, cardsWithHistory: covered, totalCards: cardIds.count)
    }

    /// When the entry entered the collection. A future-dated `acquiredAt` (typo) clamps to `addedAt`.
    static func ownedFrom(_ entry: CollectionEntry, now: Date) -> Date {
        let d = entry.acquiredAt ?? entry.addedAt
        return d > now ? entry.addedAt : d
    }

    /// Raw-market unit price at `date`: nearest history point ≤ `date`. History starting after
    /// `date` clamps to its earliest point — a card that existed but has no data holds flat
    /// instead of making the portfolio jump when its history window begins. nil = no history.
    static func rawPrice(_ history: [PricePoint], at date: Date) -> Double? {
        guard let first = history.first else { return nil }
        guard date >= first.date else { return first.value }
        // ponytail: linear scan per bucket; binary-search if collections with 10k+ entries appear.
        return history.last(where: { $0.date <= date })?.value
    }

    /// How far one history point may sit from the point before it before the newer one is read as
    /// a bad quote rather than a move. 370 of 20,431 cards on served average v44 clear it on their
    /// final step; a real 5×-in-a-week is nowhere near that common.
    /// ponytail: a flat ratio, and only the TAIL is trimmed — an outlier buried mid-series still
    /// distorts its own bucket. The tail is what the anchor and the seam depend on; widen this to
    /// a full-series filter only if mid-chart spikes are actually reported.
    static let implausibleStepRatio: Double = 5

    /// The card's history with any implausible trailing point(s) trimmed off.
    ///
    /// **Measured inside the series, never against `price_latest`.** Which of the two tables is
    /// wrong varies by card, so `raw_usd` cannot referee: `sv01-085` Kirlia is a $0.15 common with
    /// a ~$1,100 history (history wrong), while `hgss3-89` Rayquaza & Deoxys LEGEND has
    /// `raw_usd` $40 against a $199.69 history that its own `price_by_variant` Holofoil row — the
    /// row the app actually values the card from — agrees with exactly (`raw_usd` wrong). A band
    /// keyed off `raw_usd` would have discarded the honest series of the two.
    ///
    /// It does not need to referee. `scale` divides history by history, so a whole series on the
    /// wrong basis cancels out and the card simply reads flat. The one case that survives that
    /// cancellation is a bad point at the END, which becomes the anchor and turns a phantom cliff
    /// into a phantom ramp — a $100 card with months of honest history and one $2,000 point reads
    /// $5/bucket then $100. So that is the only thing trimmed, and the rest of the shape is kept.
    static func trustedHistory(_ history: [PricePoint]) -> [PricePoint] {
        var points = history
        while points.count >= 2 {
            let newest = points[points.count - 1].value, prev = points[points.count - 2].value
            guard newest > 0, prev > 0,
                  max(newest / prev, prev / newest) >= implausibleStepRatio else { break }
            points.removeLast()
        }
        return points
    }

    /// Projects today's condition/grade/printing premium backwards, anchored on the card's OWN
    /// most recent history point: multiply raw history by (current per-unit entry value ÷ that
    /// anchor). Documented approximation — exact graded history (expert tier) is a future
    /// refinement. 1 when either side is missing or the anchor is 0.
    ///
    /// **The anchor is the last history point, NOT `price_latest.raw_usd`.** Those are two
    /// different tables quoting two different subjects. `price_latest` carries a `raw_printing`
    /// basis column (pipeline #83); `price_history` has no basis column at all — it is PPT's
    /// `priceHistory.conditions["Near Mint"]` series, which has no printing dimension to record.
    /// So the two disagree freely: 1,181 of 19,461 cards on served expert v44 have a latest
    /// history point ≥5× their `raw_usd` (or vice versa), and `sv01-085` Kirlia carries a history
    /// climbing through ~$1,100 against a `raw_usd` of $0.15.
    ///
    /// Dividing history by `raw_usd` therefore built every bucket out of a ratio of two unrelated
    /// numbers, while the final bucket priced off `price_latest` alone — so the join between the
    /// two methods was discontinuous by construction. On a real 116-card tin that rendered as a
    /// vertical cliff at today's edge: $8.2k → $4,616 in one step, reported as −27% over 3M with
    /// nothing bought, sold or repriced (2026-08-15).
    ///
    /// Anchoring inside ONE series makes the last historical bucket equal the `now` bucket by
    /// construction. The cost is the leg between the last history point and today, which now
    /// reads flat — ≤7 days for 18,701 of 20,432 cards, ≤14 for 19,820.
    ///
    /// Anchoring is only half the fix and is never applied on its own: `trustedHistory` runs
    /// FIRST, because a series whose newest point is the bogus one would otherwise anchor on the
    /// bogus one and read as a phantom ramp instead of a phantom cliff.
    static func scale(_ entry: CollectionEntry, price: PriceRecord?, history: [PricePoint] = [],
                      variants: [VariantPrice], conditions: [ConditionPrice],
                      matrix: [MatrixPrice] = [], gradedByPrinting: [GradedPrintingPrice] = []) -> Double {
        guard entry.qty > 0,
              let total = GroupStats.entryValue(entry, price: price,
                                                variants: variants, conditions: conditions,
                                                matrix: matrix, gradedByPrinting: gradedByPrinting),
              // `histories` is oldest-first, so `.last` is the most recent quote. No history →
              // the caller never uses this scale (that entry holds flat at today's value).
              let anchor = history.last?.value ?? price?.rawUsd, anchor > 0 else { return 1 }
        return (total / Double(entry.qty)) / anchor
    }
}
