import XCTest
@testable import TheTin

final class PriceBandTests: XCTestCase {

    // MARK: percentiles

    func testPercentileNearestRankOverSortedSample() {
        let sorted = [1.0, 2.0, 3.0, 4.0]
        XCTAssertEqual(PriceBand.percentile(sorted, 0.25), 1.0)
        XCTAssertEqual(PriceBand.percentile(sorted, 0.50), 2.0)
        XCTAssertEqual(PriceBand.percentile(sorted, 0.75), 3.0)
    }

    func testPercentileClampsAtBothEnds() {
        let sorted = [5.0, 6.0]
        XCTAssertEqual(PriceBand.percentile(sorted, 0.0), 5.0)
        XCTAssertEqual(PriceBand.percentile(sorted, 1.0), 6.0)
    }

    // MARK: construction

    func testBandFromPurchasesOnly() {
        let band = PriceBand.make(purchases: [4, 8, 12, 16], targets: [])
        XCTAssertEqual(band?.p25, 4)
        XCTAssertEqual(band?.p50, 8)
        XCTAssertEqual(band?.p75, 12)
    }

    func testFewerThanThreeSamplesYieldsNoBand() {
        XCTAssertNil(PriceBand.make(purchases: [], targets: []))
        XCTAssertNil(PriceBand.make(purchases: [10], targets: []))
        XCTAssertNil(PriceBand.make(purchases: [10, 20], targets: []))
    }

    func testThreeSamplesIsEnough() {
        XCTAssertNotNil(PriceBand.make(purchases: [10, 20, 30], targets: []))
    }

    func testTargetsCountDoubleSoAnExplicitBudgetDominates() {
        // One target of 5 among four purchases far above it. Weighted 2x, the target pulls p25
        // down to itself; with weight 1 it would not.
        let band = PriceBand.make(purchases: [100, 100, 100, 100], targets: [5])
        XCTAssertEqual(band?.p25, 5)
    }

    func testNonPositiveAmountsAreIgnored() {
        // A zero or negative pricePaid is a data-entry artifact, not a $0 purchase.
        XCTAssertNil(PriceBand.make(purchases: [0, -1, 0], targets: []))
    }

    func testTargetsAloneCanFormABand() {
        // Two targets weighted 2x = four samples, enough on their own.
        XCTAssertNotNil(PriceBand.make(purchases: [], targets: [10, 20]))
    }

    // MARK: fit

    func testFitIsOneInsideTheBandAndAtItsEdges() {
        let band = PriceBand(p25: 10, p50: 15, p75: 20)
        XCTAssertEqual(band.fit(10), 1.0, accuracy: 0.0001)
        XCTAssertEqual(band.fit(15), 1.0, accuracy: 0.0001)
        XCTAssertEqual(band.fit(20), 1.0, accuracy: 0.0001)
    }

    func testFitFallsOffLinearlyToTheFloorOverOneBandWidth() {
        let band = PriceBand(p25: 10, p50: 15, p75: 20) // width 10
        // Half a band-width above p75 → halfway from 1.0 to the floor.
        XCTAssertEqual(band.fit(25), 1.0 - 0.5 * (1.0 - PriceBand.fitFloor), accuracy: 0.0001)
        // A full band-width above → exactly the floor.
        XCTAssertEqual(band.fit(30), PriceBand.fitFloor, accuracy: 0.0001)
    }

    func testFitIsSymmetricBelowTheBand() {
        let band = PriceBand(p25: 10, p50: 15, p75: 20)
        XCTAssertEqual(band.fit(5), 1.0 - 0.5 * (1.0 - PriceBand.fitFloor), accuracy: 0.0001)
    }

    func testPriceAloneCanNeverFullySuppressACard() {
        // A floor, not a cut: an absurdly-priced card is demoted, never scored to zero.
        // (It is NOT there to protect a grail — ForYouStream already excludes every owned
        // and wanted card from the pool, so a grail is never a candidate.)
        let band = PriceBand(p25: 10, p50: 15, p75: 20)
        XCTAssertEqual(band.fit(100_000), PriceBand.fitFloor, accuracy: 0.0001)
    }

    func testAnUnpricedCardIsNeutral() {
        // No price is not a bad price — it must not be penalised.
        let band = PriceBand(p25: 10, p50: 15, p75: 20)
        XCTAssertEqual(band.fit(nil), 1.0, accuracy: 0.0001)
    }

    func testADegenerateZeroWidthBandDoesNotDivideByZero() {
        let band = PriceBand(p25: 10, p50: 10, p75: 10)
        XCTAssertEqual(band.fit(10), 1.0, accuracy: 0.0001)
        XCTAssertEqual(band.fit(1000), PriceBand.fitFloor, accuracy: 0.0001)
    }

    // MARK: building from real records

    private func entry(_ id: String, paid: Double?, acquired: Date?, sold: Bool = false) -> CollectionEntry {
        var e = CollectionEntry(id: id, cardId: "c-\(id)", groupId: "", qty: 1, condition: nil,
                                grade: nil, pricePaid: paid, acquiredAt: acquired, acquiredFrom: nil,
                                addedAt: Date(timeIntervalSince1970: 0))
        if sold { e.soldAt = Date(timeIntervalSince1970: 0) }
        return e
    }

    /// Fixed clock — `Date()` in a test is a flake waiting to happen.
    private let now = Date(timeIntervalSince1970: 1_780_000_000) // 2026-06-08

    private func monthsAgo(_ months: Int) -> Date {
        now.addingTimeInterval(-Double(months) * 30.4 * 86_400)
    }

    func testBandFromEntriesUsesPricePaid() {
        let entries = [entry("1", paid: 4, acquired: monthsAgo(1)),
                       entry("2", paid: 8, acquired: monthsAgo(2)),
                       entry("3", paid: 12, acquired: monthsAgo(3)),
                       entry("4", paid: 16, acquired: monthsAgo(4))]
        let band = PriceBand.make(entries: entries, wants: [:], now: now)
        XCTAssertEqual(band?.p25, 4)
        XCTAssertEqual(band?.p75, 12)
    }

    func testPurchasesOlderThanTwoYearsAreExcluded() {
        // Three recent, plus one ancient outlier that would drag p75 up if it counted.
        let entries = [entry("1", paid: 10, acquired: monthsAgo(1)),
                       entry("2", paid: 10, acquired: monthsAgo(2)),
                       entry("3", paid: 10, acquired: monthsAgo(3)),
                       entry("old", paid: 9_999, acquired: monthsAgo(30))]
        let band = PriceBand.make(entries: entries, wants: [:], now: now)
        XCTAssertEqual(band?.p75, 10)
    }

    func testAnEntryWithNoAcquiredDateStillCounts() {
        // pricePaid IS the signal; a missing date is an unrecorded detail, not evidence of staleness.
        let entries = [entry("1", paid: 10, acquired: nil),
                       entry("2", paid: 20, acquired: nil),
                       entry("3", paid: 30, acquired: nil)]
        XCTAssertNotNil(PriceBand.make(entries: entries, wants: [:], now: now))
    }

    func testEntriesWithNoPricePaidContributeNothing() {
        let entries = [entry("1", paid: nil, acquired: monthsAgo(1)),
                       entry("2", paid: nil, acquired: monthsAgo(1)),
                       entry("3", paid: nil, acquired: monthsAgo(1))]
        XCTAssertNil(PriceBand.make(entries: entries, wants: [:], now: now))
    }

    func testSoldEntriesAreExcluded() {
        // A sold copy is not evidence of what you buy now.
        let entries = [entry("1", paid: 10, acquired: monthsAgo(1), sold: true),
                       entry("2", paid: 10, acquired: monthsAgo(1), sold: true),
                       entry("3", paid: 10, acquired: monthsAgo(1), sold: true)]
        XCTAssertNil(PriceBand.make(entries: entries, wants: [:], now: now))
    }

    /// ⚠️ Regression, found on real data 2026-08-04. Six purchases at $5–66 plus three wishlist
    /// targets at $90–250 produced a band of $6.24–$200 — which made `fit()` return 1.0 for
    /// virtually the whole catalog, so the band was a measured no-op. A `targetUsd` is a ceiling
    /// for ONE expensive card, not evidence of typical spend, so it must not widen the band when
    /// real purchase history exists.
    func testAspirationalTargetsDoNotWidenABandBuiltFromRealPurchases() {
        let entries = [entry("1", paid: 5, acquired: monthsAgo(1)),
                       entry("2", paid: 5.13, acquired: monthsAgo(1)),
                       entry("3", paid: 6.24, acquired: monthsAgo(1)),
                       entry("4", paid: 17.71, acquired: monthsAgo(1)),
                       entry("5", paid: 33.55, acquired: monthsAgo(1)),
                       entry("6", paid: 65.73, acquired: monthsAgo(1))]
        let wants: [String: WantEntry] = [
            "a": WantEntry(priority: .normal, targetUsd: 250),
            "b": WantEntry(priority: .normal, targetUsd: 90),
            "c": WantEntry(priority: .normal, targetUsd: 200),
        ]
        let band = try! XCTUnwrap(PriceBand.make(entries: entries, wants: wants, now: now))
        XCTAssertEqual(band.p75, 33.55, "p75 must come from purchases, not from grail targets")
        XCTAssertLessThan(band.p75, 100)
    }

    func testTargetsStillBuildABandWhenThereIsNoPurchaseHistory() {
        // Cold start: three targets are better than no band at all.
        let wants: [String: WantEntry] = [
            "a": WantEntry(priority: .normal, targetUsd: 10),
            "b": WantEntry(priority: .normal, targetUsd: 20),
        ]
        XCTAssertNotNil(PriceBand.make(entries: [], wants: wants, now: now))
    }

    func testTargetsFillInWhenPurchasesAreTooFewToFormABand() {
        // Two purchases is under `minimumSamples`, so the targets must be allowed to carry it.
        let entries = [entry("1", paid: 8, acquired: monthsAgo(1)),
                       entry("2", paid: 9, acquired: monthsAgo(1))]
        let wants: [String: WantEntry] = ["a": WantEntry(priority: .normal, targetUsd: 30)]
        XCTAssertNotNil(PriceBand.make(entries: entries, wants: wants, now: now))
    }

    func testWishlistTargetsFeedTheBand() {
        let wants: [String: WantEntry] = [
            "a": WantEntry(priority: .normal, targetUsd: 6),
            "b": WantEntry(priority: .normal, targetUsd: 10),
        ]
        // Two targets at weight 2 = four samples, enough on their own.
        XCTAssertNotNil(PriceBand.make(entries: [], wants: wants, now: now))
    }

    func testNoDataAtAllYieldsNoBand() {
        XCTAssertNil(PriceBand.make(entries: [], wants: [:], now: now))
    }
}
