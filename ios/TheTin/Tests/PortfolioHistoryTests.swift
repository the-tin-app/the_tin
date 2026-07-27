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

extension PortfolioHistoryTests {
    private func sold(_ id: String, card: String, paid: Double, soldFor: Double?,
                      soldAt: Date, added: Date) -> CollectionEntry {
        var e = entry(id, card: card, paid: paid, added: added)
        e.soldAt = soldAt
        e.soldFor = soldFor
        return e
    }

    /// The exact case measured on device, 2026-07-26: paid 170, worth 163, sold for 155.
    ///
    /// The sale realises a $15 LOSS, so "Change vs. paid" must get worse. Before the fix a sold
    /// card left `entries` entirely, taking its 170 of basis out alongside its 163 of value — and
    /// the number went UP $7. The error was exactly the realised loss.
    func testSellingAtALossMakesChangeVsPaidWorseNotBetter() {
        let history = ["A": flat(163, days: [0, 7, 14]), "B": flat(1000, days: [0, 7, 14])]
        let keep = entry("keep", card: "B", paid: 5, added: day(0))

        let holding = [keep, entry("a", card: "A", paid: 170, added: day(0))]
        let before = PortfolioHistory.series(entries: holding, histories: history, prices: [:],
                                             variantsByCard: [:], conditionsByCard: [:], now: day(14))
        let b = try! XCTUnwrap(before.points.last)
        let changeBefore = b.value + b.realised - b.costBasis

        let after = PortfolioHistory.series(
            entries: [keep, sold("a", card: "A", paid: 170, soldFor: 155, soldAt: day(10), added: day(0))],
            histories: history, prices: [:], variantsByCard: [:], conditionsByCard: [:], now: day(14))
        let a = try! XCTUnwrap(after.points.last)
        let changeAfter = a.value + a.realised - a.costBasis

        XCTAssertEqual(a.costBasis, 175, "money spent doesn't un-spend itself when you sell")
        XCTAssertEqual(a.realised, 155, "what you actually got has to land somewhere")
        XCTAssertEqual(a.value, 1000, accuracy: 0.001, "held value excludes the sold copy")
        // Sold $8 under the $163 it was worth, so the comparison worsens by exactly 8.
        XCTAssertEqual(changeAfter, changeBefore - 8, accuracy: 0.001)
        XCTAssertLessThan(changeAfter, changeBefore, "a loss must never improve the number")
    }

    /// The chart line still means "what I hold", so the last bucket keeps matching the tin header.
    func testSoldCopyLeavesTheValueLineButNotTheBasis() {
        let e = sold("a", card: "A", paid: 100, soldFor: 90, soldAt: day(7), added: day(0))
        let s = PortfolioHistory.series(entries: [e], histories: ["A": flat(120, days: [0, 7, 14])],
                                        prices: [:], variantsByCard: [:], conditionsByCard: [:],
                                        now: day(14))
        let first = try! XCTUnwrap(s.points.first)
        let last = try! XCTUnwrap(s.points.last)
        XCTAssertEqual(first.value, 120, accuracy: 0.001, "still held at day 0")
        XCTAssertEqual(first.realised, 0)
        XCTAssertEqual(last.value, 0, accuracy: 0.001, "gone by day 14")
        XCTAssertEqual(last.realised, 90)
        XCTAssertEqual(last.costBasis, 100)
        XCTAssertEqual(s.totalCards, 0, "coverage counts what you still own")
    }

    /// A trade or a gift has no cash figure. The copy still leaves, and nothing is invented.
    func testTradedAwayCopyRealisesNothing() {
        let e = sold("a", card: "A", paid: 100, soldFor: nil, soldAt: day(7), added: day(0))
        let s = PortfolioHistory.series(entries: [e], histories: ["A": flat(120, days: [0, 7, 14])],
                                        prices: [:], variantsByCard: [:], conditionsByCard: [:],
                                        now: day(14))
        let last = try! XCTUnwrap(s.points.last)
        XCTAssertEqual(last.realised, 0)
        XCTAssertEqual(last.costBasis, 100)
    }
}
