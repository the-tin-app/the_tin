import XCTest
@testable import TheTin

final class PortfolioHistoryTests: XCTestCase {
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 86_400) }

    private func entry(_ id: String, card: String, qty: Int = 1, paid: Double? = nil,
                       acquired: Date? = nil, added: Date, condition: String = "NM") -> CollectionEntry {
        CollectionEntry(id: id, cardId: card, groupId: "", qty: qty, condition: condition, grade: nil,
                        pricePaid: paid, acquiredAt: acquired, acquiredFrom: nil, addedAt: added, variant: nil)
    }

    private func flat(_ value: Double, days: [Int]) -> [PricePoint] {
        days.map { PricePoint(date: day($0), value: value) }
    }

    func testMidRangeAcquisitionEntersOnItsBucket() {
        // A owned from day 0; B acquired day 14 — B's $20 must appear exactly at the day-14 bucket.
        let entries = [entry("a", card: "A", added: day(0)),
                       entry("b", card: "B", acquired: day(14), added: day(20))]
        let histories = ["A": flat(10, days: [0, 7, 14, 21]),
                         "B": flat(20, days: [0, 7, 14, 21])]
        let s = PortfolioHistory.series(entries: entries, histories: histories, prices: [:],
                                        variantsByCard: [:], conditionsByCard: [:], now: day(21))
        XCTAssertEqual(s.points.map(\.date), [day(0), day(7), day(14), day(21)])
        XCTAssertEqual(s.points.map(\.value), [10, 10, 30, 30])
    }

    func testQtyMultipliesUnitPrice() {
        let entries = [entry("a", card: "A", qty: 3, added: day(0))]
        let s = PortfolioHistory.series(entries: entries, histories: ["A": flat(10, days: [0, 7])],
                                        prices: [:], variantsByCard: [:], conditionsByCard: [:], now: day(7))
        XCTAssertEqual(s.points.map(\.value), [30, 30])
    }

    func testHistoryStartingLateClampsToItsEarliestPoint() {
        // Card owned from day 0, but its history only starts day 14 at $50: earlier buckets hold
        // flat at $50 (no fabricated zeros, no jump when the history window begins).
        let entries = [entry("a", card: "A", added: day(0))]
        let histories = ["A": [PricePoint(date: day(14), value: 50), PricePoint(date: day(21), value: 60)]]
        let s = PortfolioHistory.series(entries: entries, histories: histories, prices: [:],
                                        variantsByCard: [:], conditionsByCard: [:], now: day(21))
        XCTAssertEqual(s.points.map(\.value), [50, 50, 50, 60])
    }

    func testConditionScalingProjectsTodaysPremiumBackwards() {
        // Today: DMG $5 vs raw $10 → scale 0.5. History point $40 → $20 on a PAST bucket; the
        // final "now" bucket prices at today's actual value ($5), not the stale history point.
        let price = PriceRecord(cardId: "A", rawUsd: 10, rawEur: nil, psa3: nil, psa7: nil,
                                psa9: nil, psa10: nil, asOf: "2026-07-14")
        let entries = [entry("a", card: "A", added: day(0), condition: "DMG")]
        let s = PortfolioHistory.series(entries: entries,
                                        histories: ["A": [PricePoint(date: day(0), value: 40)]],
                                        prices: ["A": price], variantsByCard: [:],
                                        conditionsByCard: ["A": [ConditionPrice(condition: .damaged, usd: 5)]],
                                        now: day(7))
        XCTAssertEqual(s.points.map(\.value), [20, 5])
    }

    func testNowBucketMatchesHeaderMathAndNoHistoryHoldsFlat() {
        // The bug report shape: header and portfolio disagreed in both directions.
        // A: history lags ($8/week-old point) but today's raw is $10 → "now" uses $10.
        // B: no history at all → holds flat at today's $5 instead of vanishing from the chart.
        let priceA = PriceRecord(cardId: "A", rawUsd: 10, rawEur: nil, psa3: nil, psa7: nil,
                                 psa9: nil, psa10: nil, asOf: "2026-07-16")
        let priceB = PriceRecord(cardId: "B", rawUsd: 5, rawEur: nil, psa3: nil, psa7: nil,
                                 psa9: nil, psa10: nil, asOf: "2026-07-16")
        let entries = [entry("a", card: "A", added: day(0)),
                       entry("b", card: "B", qty: 2, added: day(0))]
        let s = PortfolioHistory.series(entries: entries,
                                        histories: ["A": flat(8, days: [0, 7]), "B": []],
                                        prices: ["A": priceA, "B": priceB],
                                        variantsByCard: [:], conditionsByCard: [:], now: day(14))
        // day 0 + 7: A at history×scale (8 × 10/10) + B flat at 2×$5. day 14 ("now"): header math.
        XCTAssertEqual(s.points.map(\.value), [18, 18, 20])
        let header = GroupStats.totalValue(entries: entries, prices: ["A": priceA, "B": priceB])
        XCTAssertEqual(s.points.last?.value, header.total)
    }

    func testCostBasisAccumulatesPerEntryTotals() {
        // pricePaid is the per-entry TOTAL: the qty-2 entry adds 50, not 100. Entries whose card
        // has no history still count toward cost basis.
        let entries = [entry("a", card: "A", paid: 30, added: day(0)),
                       entry("b", card: "B", qty: 2, paid: 50, acquired: day(14), added: day(14))]
        let s = PortfolioHistory.series(entries: entries, histories: ["A": flat(1, days: [0])],
                                        prices: [:], variantsByCard: [:], conditionsByCard: [:], now: day(14))
        XCTAssertEqual(s.points.map(\.costBasis), [30, 30, 80])
    }

    func testZeroQtyEntryDoesNotProduceNaN() {
        // qty == 0 would divide-by-zero in `scale` (total / qty); guard must short-circuit to
        // scale 1 instead of NaN, which would otherwise poison every bucket's value.
        let price = PriceRecord(cardId: "A", rawUsd: 10, rawEur: nil, psa3: nil, psa7: nil,
                                psa9: nil, psa10: nil, asOf: "2026-07-14")
        let entries = [entry("a", card: "A", qty: 0, added: day(0))]
        let s = PortfolioHistory.series(entries: entries,
                                        histories: ["A": flat(10, days: [0])],
                                        prices: ["A": price], variantsByCard: [:], conditionsByCard: [:],
                                        now: day(0))
        for point in s.points {
            XCTAssertFalse(point.value.isNaN)
            XCTAssertEqual(point.value, 0)   // qty 0 contributes nothing, not NaN
        }
    }

    func testCoverageCountsDistinctCards() {
        // Two entries of card A count A once; C's empty history array doesn't count as covered.
        let entries = [entry("a1", card: "A", added: day(0)), entry("a2", card: "A", added: day(0)),
                       entry("b", card: "B", added: day(0)), entry("c", card: "C", added: day(0))]
        let histories = ["A": flat(1, days: [0]), "B": flat(2, days: [0]), "C": []]
        let s = PortfolioHistory.series(entries: entries, histories: histories, prices: [:],
                                        variantsByCard: [:], conditionsByCard: [:], now: day(0))
        XCTAssertEqual(s.cardsWithHistory, 2)
        XCTAssertEqual(s.totalCards, 3)
    }
}
