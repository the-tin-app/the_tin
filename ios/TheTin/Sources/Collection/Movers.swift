import Foundation

/// "What moved in your tin" — the reason to open the app tomorrow.
///
/// The widget has computed a 7-day delta since the collection first shipped; the app itself never
/// showed one, so a daily check-in met the same total, the same rows, and no answer to "did
/// anything happen?". This is that answer, in the units that matter: dollars of *your* holding,
/// not headline percentages of cards you own one cheap copy of.
///
/// Runs entirely off `price_delta`, which ships in EVERY catalog tier (only `price_history_cond`
/// and `graded_history` are ever dropped, and `price_history` merely emptied) — so this works on
/// the Small catalog, where the portfolio chart cannot.
enum Movers {
    /// One card's movement. Rows are per *card*, not per entry: a card held as both a raw and a
    /// graded copy moves on two different price series, and the collector thinks of it as one card.
    struct Row: Identifiable, Equatable {
        let cardId: String
        /// Physical copies contributing (Σ qty of the entries that had both a price and a change).
        let qty: Int
        /// What those copies are worth now.
        let value: Double
        /// Dollars this holding gained (+) or lost (−) over the period.
        let impact: Double
        var id: String { cardId }

        /// The holding's aggregate percent move, derived back out of the money so a card valued
        /// on two different rungs still reports one honest number. nil when it was worthless
        /// before (a card that appeared from nothing has no meaningful percentage).
        var pct: Double? {
            let before = value - impact
            return before > 0 ? impact / before : nil
        }
    }

    struct Summary: Equatable {
        /// Cards that actually moved, largest absolute dollar impact first.
        var rows: [Row] = []
        /// Net change across the whole tin over the period.
        var totalImpact: Double = 0
        /// Distinct cards that had both a value and a usable change for this period — the honest
        /// denominator for "based on N of M cards", mirroring PortfolioView's coverage note.
        var cardsWithData: Int = 0
        /// Distinct cards owned, whether or not they had change data.
        var totalCards: Int = 0
    }

    /// Impact below half a cent is rounding noise; including it pads the list with rows that
    /// render as "$0.00" and say nothing.
    private static let minimumImpact = 0.005

    static func summary(entries: [CollectionEntry], prices: [String: PriceRecord],
                        deltasByCard: [String: [DeltaRecord]],
                        variantsByCard: [String: [VariantPrice]] = [:],
                        conditionsByCard: [String: [ConditionPrice]] = [:],
                        matrixByCard: [String: [MatrixPrice]] = [:],
                        gradedByPrintingByCard: [String: [GradedPrintingPrice]] = [:],
                        period: DeltaPeriod) -> Summary {
        var valueByCard: [String: Double] = [:]
        var impactByCard: [String: Double] = [:]
        var qtyByCard: [String: Int] = [:]
        var ownedCards = Set<String>()

        for entry in entries {
            ownedCards.insert(entry.cardId)
            guard let value = GroupStats.entryValue(
                entry, price: prices[entry.cardId],
                variants: variantsByCard[entry.cardId] ?? [],
                conditions: conditionsByCard[entry.cardId] ?? [],
                matrix: matrixByCard[entry.cardId] ?? [],
                gradedByPrinting: gradedByPrintingByCard[entry.cardId] ?? []) else { continue }
            // `unitDelta` is the change counterpart of the same ladder `entryValue` walks, so the
            // percentage always belongs to the price the value was taken from — a played copy
            // reports its condition's move, not the raw market's.
            guard let pct = GroupStats.unitDelta(entry, records: deltasByCard[entry.cardId] ?? [])?
                    .pct(for: period), pct > -1 else { continue }
            // pct is measured against the earlier price, so the earlier value is value / (1 + pct).
            // Using `value × pct` instead would overstate every gain and understate every loss.
            let impact = value - value / (1 + pct)
            valueByCard[entry.cardId, default: 0] += value
            impactByCard[entry.cardId, default: 0] += impact
            qtyByCard[entry.cardId, default: 0] += entry.qty
        }

        let rows = impactByCard
            .filter { abs($0.value) >= minimumImpact }
            .map { cardId, impact in
                Row(cardId: cardId, qty: qtyByCard[cardId] ?? 0,
                    value: valueByCard[cardId] ?? 0, impact: impact)
            }
            // Dollar impact on the tin, not raw percent: a $300 card moving 4% outranks a 40c
            // common that doubled. Ties break on id so the order is stable between launches.
            .sorted { a, b in
                let (x, y) = (abs(a.impact), abs(b.impact))
                return x == y ? a.cardId < b.cardId : x > y
            }

        return Summary(rows: rows,
                       totalImpact: impactByCard.values.reduce(0, +),
                       cardsWithData: impactByCard.count,
                       totalCards: ownedCards.count)
    }
}
