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
        // Today: DMG $5 against the card's latest history point of $10 → scale 0.5. The card
        // halved over the window ($20 → $10), so the DMG copy reads $10 → $5, and the final
        // "now" bucket prices at today's actual value ($5).
        let price = PriceRecord(cardId: "A", rawUsd: 10, rawEur: nil, psa3: nil, psa7: nil,
                                psa9: nil, psa10: nil, asOf: "2026-07-14")
        let entries = [entry("a", card: "A", added: day(0), condition: "DMG")]
        let histories = ["A": [PricePoint(date: day(0), value: 20), PricePoint(date: day(7), value: 10)]]
        let s = PortfolioHistory.series(entries: entries, histories: histories,
                                        prices: ["A": price], variantsByCard: [:],
                                        conditionsByCard: ["A": [ConditionPrice(condition: .damaged, usd: 5)]],
                                        now: day(14))
        XCTAssertEqual(s.points.map(\.value), [10, 5, 5])
    }

    func testHistoryOnADifferentBasisThanRawUsdDoesNotCliffAtToday() {
        // `price_history` carries no basis column; `price_latest.raw_usd` carries `raw_printing`.
        // When they quote different subjects the old scale (÷ raw_usd) built the whole curve out
        // of a ratio of two unrelated numbers while the last bucket priced off `price_latest`
        // alone — a vertical drop at today's edge that no holding actually took.
        //
        // Shape of the real report (sv01-085 Kirlia, served expert v44): history sitting near
        // $1,100 while raw_usd is $0.15. Old math: past buckets 1100 × (0.15/0.15) = $1,100 each,
        // "now" $0.15 — a 7,000× cliff. Anchored on the series' own last point the curve is flat,
        // which is what a flat history means.
        let price = PriceRecord(cardId: "A", rawUsd: 0.15, rawEur: nil, psa3: nil, psa7: nil,
                                psa9: nil, psa10: nil, asOf: "2026-08-15")
        let entries = [entry("a", card: "A", added: day(0))]
        let s = PortfolioHistory.series(entries: entries, histories: ["A": flat(1100, days: [0, 7])],
                                        prices: ["A": price], variantsByCard: [:], conditionsByCard: [:],
                                        now: day(14))
        XCTAssertEqual(s.points.map(\.value), [0.15, 0.15, 0.15])
        // The invariant that was violated: the last historical bucket must join the "now" bucket.
        let last = s.points.map(\.value).suffix(2)
        XCTAssertEqual(last.first!, last.last!, accuracy: 0.0001)
    }

    func testImplausibleTrailingPointIsTrimmedNotUsedAsTheAnchor() {
        // The failure mode anchoring ALONE introduces, and the only thing the trim exists for.
        // A real $100 card with months of honest history and one $2,000 point: dividing by
        // raw_usd puts a $2,000 spike in the second-to-last bucket, and anchoring on the $2,000
        // instead reads $5/bucket ramping to $100 — a phantom cliff traded for a phantom ramp.
        // The bad point goes; the honest months stay and still count as coverage.
        let price = PriceRecord(cardId: "A", rawUsd: 100, rawEur: nil, psa3: nil, psa7: nil,
                                psa9: nil, psa10: nil, asOf: "2026-08-15")
        let entries = [entry("a", card: "A", added: day(0))]
        let histories = ["A": flat(100, days: [0, 7]) + [PricePoint(date: day(14), value: 2000)]]
        let s = PortfolioHistory.series(entries: entries, histories: histories, prices: ["A": price],
                                        variantsByCard: [:], conditionsByCard: [:], now: day(21))
        XCTAssertEqual(s.points.map(\.value), [100, 100, 100, 100])
        XCTAssertEqual(s.cardsWithHistory, 1)
    }

    func testWholeSeriesOnADifferentBasisThanRawUsdIsKept() {
        // `hgss3-89` Rayquaza & Deoxys LEGEND, served average v44: raw_usd $40 against a $199.69
        // history that the card's own `price_by_variant` Holofoil row — the row the app values it
        // from — matches exactly. Here `raw_usd` is the wrong number, so a trust test keyed off it
        // would discard the honest series. The trim only looks INSIDE the series, and a smooth
        // series has no step to trim: the card keeps its shape and its coverage.
        let price = PriceRecord(cardId: "A", rawUsd: 40, rawEur: nil, psa3: nil, psa7: nil,
                                psa9: nil, psa10: nil, asOf: "2026-08-15")
        let entries = [entry("a", card: "A", added: day(0))]
        let histories = ["A": [PricePoint(date: day(0), value: 180), PricePoint(date: day(7), value: 199.69)]]
        let s = PortfolioHistory.series(entries: entries, histories: histories, prices: ["A": price],
                                        variantsByCard: [:], conditionsByCard: [:], now: day(14))
        XCTAssertEqual(s.cardsWithHistory, 1)
        // Anchored on its own last point, so the seam still closes: last bucket == "now".
        let vals = s.points.map(\.value)
        XCTAssertEqual(vals.count, 3)
        XCTAssertEqual(vals[0], 36.06, accuracy: 0.01)   // 180 × (40 ÷ 199.69)
        XCTAssertEqual(vals[1], 40, accuracy: 0.01)
        XCTAssertEqual(vals[2], 40, accuracy: 0.01)
    }

    func testOrdinaryMovementIsNotTrimmed() {
        // The trim must not swallow ordinary moves: $60 → $100 is a real 67% run and survives,
        // anchored so the last bucket still joins "now".
        let price = PriceRecord(cardId: "A", rawUsd: 100, rawEur: nil, psa3: nil, psa7: nil,
                                psa9: nil, psa10: nil, asOf: "2026-08-15")
        let entries = [entry("a", card: "A", added: day(0))]
        let histories = ["A": [PricePoint(date: day(0), value: 60), PricePoint(date: day(7), value: 100)]]
        let s = PortfolioHistory.series(entries: entries, histories: histories, prices: ["A": price],
                                        variantsByCard: [:], conditionsByCard: [:], now: day(14))
        XCTAssertEqual(s.points.map(\.value), [60, 100, 100])
        XCTAssertEqual(s.cardsWithHistory, 1)
    }

    func testGradedEntryTracksHistoryShapeWithoutRawUsdAmplification() {
        // A slab is valued off `psa10`, so the old scale was psa10 ÷ raw_usd — a ratio across two
        // subjects that multiplied every history point by ~100 when the two disagreed. Anchored
        // on the card's own last point, the slab tracks the history's SHAPE (halved) from today's
        // $2,000, and the last historical bucket still joins "now".
        let price = PriceRecord(cardId: "A", rawUsd: 5, rawEur: nil, psa3: nil, psa7: nil,
                                psa9: nil, psa10: 2000, asOf: "2026-08-15")
        var e = entry("a", card: "A", added: day(0))
        e.grade = "psa10"
        let histories = ["A": [PricePoint(date: day(0), value: 40), PricePoint(date: day(7), value: 20)]]
        let s = PortfolioHistory.series(entries: [e], histories: histories, prices: ["A": price],
                                        variantsByCard: [:], conditionsByCard: [:], now: day(14))
        XCTAssertEqual(s.points.map(\.value), [4000, 2000, 2000])
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
        // day 0 + 7: A anchored on its OWN last point (8 × 10/8 = $10) + B flat at 2×$5. day 14
        // ("now"): header math, $20 — the same number, so the stale leg reads flat.
        //
        // It used to read [18, 18, 20]: A's history was divided by `raw_usd` instead of by its own
        // anchor, so the week between A's last quote and today rendered as a step. That step is
        // the same arithmetic that produced a −27% cliff on a real tin when the two tables quoted
        // different subjects (see `testHistoryOnADifferentBasisThanRawUsdDoesNotCliffAtToday`),
        // and it cannot be kept selectively — the client cannot tell a lagging quote from a
        // mismatched one. Losing ≤7 days of real movement is the deliberate price.
        XCTAssertEqual(s.points.map(\.value), [20, 20, 20])
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
