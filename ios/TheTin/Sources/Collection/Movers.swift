import Foundation

/// "What moved in your tin" — the reason to open the app tomorrow.
///
/// The widget has computed a 7-day delta since the collection first shipped; the app itself never
/// showed one, so a daily check-in met the same total, the same rows, and no answer to "did
/// anything happen?". This is that answer, in the units that matter: dollars of *your* holding,
/// not headline percentages of cards you own one cheap copy of.
///
/// Runs entirely off `price_delta`. That table is **emptied on the casual (Small) tier**, exactly
/// like `price_history` — `publish-tiers.ts` deletes its rows — so Movers has nothing to show
/// there and says so in the same words the portfolio and price-history charts use. (An earlier
/// version of this comment claimed every tier carried it. It does not.)
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

    /// A catalog-wide mover — a card the market moved, owned or not. No quantity, because it's
    /// about the card rather than a holding.
    struct MarketRow: Identifiable, Equatable {
        let cardId: String
        /// Which printing moved, when the change is per-printing. nil for single-printing cards
        /// quoted on the raw series. Shown, because "Charizard +40%" means different things for
        /// Unlimited and 1st Edition.
        let printing: String?
        let pct: Double
        let usd: Double
        var id: String { cardId }
    }

    /// A guard against quotes that were wrong yesterday, not a claim about the market.
    ///
    /// It was built for basis flips — `price_latest.raw_usd` changing WHICH printing it quoted
    /// between nightly artifacts, so the "change" was the spread between two printings, which is
    /// how a card sat at +1800% while its own detail screen said +0.2%. The pipeline fixed that
    /// (`raw_printing`, IMPROVEMENTS #3): raw deltas past 500% went **47 → 2** between v23 and
    /// v25, and the 100–500% band 450 → 8.
    ///
    /// The ceiling stays because the residue has a different cause. Measured on v25 (2026-07-27),
    /// six rows catalog-wide still clear 500% (2 `raw` + 4 `printing`, per `docs/IMPROVEMENTS.md`
    /// — not a regression of the 47 → 2 fix above, a different, smaller basis: `printing` deltas
    /// weren't part of that count), and they're thin-market SKUs correcting a stale
    /// quote: `neo4-107` Shining Charizard went $20 → $3998.99 overnight with `raw_printing`
    /// unchanged on both sides. A corrected quote is not a move your tin made, and `topMovers`
    /// sorts by `ABS(pct)`, so without this the least trustworthy row in the catalog leads the
    /// screen.
    /// ponytail: a flat ceiling, deliberately. Upgrade path is a sanity check on the *previous*
    /// price (was it quoted from a real sale?), not a bigger number here.
    static let implausiblePct: Double = 5.0

    /// Below this the list fills with commons whose "moves" are rounding noise on a few cents.
    /// ponytail: a flat floor, not a percentile — revisit if it hides real movement in cheap sets.
    static let marketFloorUsd: Double = 5

    /// How many catalog movers to fetch. Enough to scroll, small enough to stay one cheap query.
    static let marketLimit = 100

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
            let variants = variantsByCard[entry.cardId] ?? []
            let conditions = conditionsByCard[entry.cardId] ?? []
            let matrix = matrixByCard[entry.cardId] ?? []
            let gradedByPrinting = gradedByPrintingByCard[entry.cardId] ?? []
            // Only copies the catalog can price EXACTLY. `entryValue` alone walks a fallback
            // ladder and will happily return the raw market price for a card you hold in DMG that
            // has no DMG price — and then `unitDelta` reports the RAW market's move, so the screen
            // says a played copy did what a mint one did. The tin total may estimate (it says so);
            // a screen whose whole claim is "this card moved your tin by $X" may not.
            guard GroupStats.isPricedExactly(
                entry, price: prices[entry.cardId], variants: variants, conditions: conditions,
                matrix: matrix, gradedByPrinting: gradedByPrinting) else { continue }
            guard let value = GroupStats.entryValue(
                entry, price: prices[entry.cardId],
                variants: variants, conditions: conditions,
                matrix: matrix, gradedByPrinting: gradedByPrinting) else { continue }
            // `unitDelta` is the change counterpart of the same ladder `entryValue` walks, so the
            // percentage always belongs to the price the value was taken from — a played copy
            // reports its condition's move, not the raw market's.
            guard let pct = GroupStats.unitDelta(entry, records: deltasByCard[entry.cardId] ?? [])?
                    .pct(for: period), pct > -1 else { continue }
            // Same basis-flip guard as the market list: an entry with no printing recorded falls
            // through to the raw rung, which can quote a different printing than it did yesterday.
            // Better to omit the card than to claim your tin gained 1800%.
            guard abs(pct) <= implausiblePct else { continue }
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
