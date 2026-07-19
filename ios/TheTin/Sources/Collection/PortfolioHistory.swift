import Foundation

/// One weekly bucket of the portfolio series.
struct PortfolioPoint: Equatable {
    let date: Date
    let value: Double
    let costBasis: Double
}

/// The series plus history coverage (UI: "based on X of Y cards" when < 100%).
struct PortfolioSeries: Equatable {
    let points: [PortfolioPoint]
    let cardsWithHistory: Int
    let totalCards: Int
}

/// Reconstructs the collection's value over time from per-card weekly `price_history`. Pure —
/// no I/O, no clock reads beyond the injected `now`. The series is always recomputed from live
/// entries (no tombstones): it shows the *current* collection's past value, by design.
enum PortfolioHistory {
    private static let week: TimeInterval = 7 * 86_400

    /// `histories` values must be oldest-first (as `CatalogStore.priceHistory` returns them).
    /// The trailing defaulted `now:` exists for tests — the pinned 5-argument call shape
    /// (widget feature) compiles unchanged.
    static func series(entries: [CollectionEntry],
                       histories: [String: [PricePoint]],
                       prices: [String: PriceRecord],
                       variantsByCard: [String: [VariantPrice]],
                       conditionsByCard: [String: [ConditionPrice]],
                       matrixByCard: [String: [MatrixPrice]] = [:],
                       gradedByPrintingByCard: [String: [GradedPrintingPrice]] = [:],
                       now: Date = Date()) -> PortfolioSeries {
        let cardIds = Set(entries.map(\.cardId))
        let covered = cardIds.filter { !(histories[$0] ?? []).isEmpty }.count
        // Per-entry constants, hoisted out of the bucket loop.
        let ownedDates = entries.map { ownedFrom($0, now: now) }
        let scales = entries.map { scale($0, price: prices[$0.cardId],
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
            let isNow = bucket == dates.count - 1
            for (i, entry) in entries.enumerated() where ownedDates[i] <= date {
                basis += entry.pricePaid ?? 0   // per-entry TOTAL — never × qty (spec, resolved 2026-07-14)
                let history = histories[entry.cardId] ?? []
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
            return PortfolioPoint(date: date, value: value, costBasis: basis)
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

    /// Projects today's condition/grade/printing premium backwards: multiply raw history by
    /// (current per-unit entry value ÷ current rawUsd). Documented approximation — exact graded
    /// history (expert tier) is a future refinement. 1 when either side is missing or raw is 0.
    static func scale(_ entry: CollectionEntry, price: PriceRecord?,
                      variants: [VariantPrice], conditions: [ConditionPrice],
                      matrix: [MatrixPrice] = [], gradedByPrinting: [GradedPrintingPrice] = []) -> Double {
        guard entry.qty > 0,
              let total = GroupStats.entryValue(entry, price: price,
                                                variants: variants, conditions: conditions,
                                                matrix: matrix, gradedByPrinting: gradedByPrinting),
              let raw = price?.rawUsd, raw > 0 else { return 1 }
        return (total / Double(entry.qty)) / raw
    }
}
