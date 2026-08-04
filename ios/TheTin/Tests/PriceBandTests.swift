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
        // Half a band-width above p75 → halfway from 1.0 to the 0.35 floor.
        XCTAssertEqual(band.fit(25), 0.675, accuracy: 0.0001)
        // A full band-width above → exactly the floor.
        XCTAssertEqual(band.fit(30), 0.35, accuracy: 0.0001)
    }

    func testFitIsSymmetricBelowTheBand() {
        let band = PriceBand(p25: 10, p50: 15, p75: 20)
        XCTAssertEqual(band.fit(5), 0.675, accuracy: 0.0001)
    }

    func testPriceAloneCanNeverFullySuppressACard() {
        // The whole point of a floor: a grail priced absurdly far above the band stays rankable.
        let band = PriceBand(p25: 10, p50: 15, p75: 20)
        XCTAssertEqual(band.fit(100_000), 0.35, accuracy: 0.0001)
    }

    func testAnUnpricedCardIsNeutral() {
        // No price is not a bad price — it must not be penalised.
        let band = PriceBand(p25: 10, p50: 15, p75: 20)
        XCTAssertEqual(band.fit(nil), 1.0, accuracy: 0.0001)
    }

    func testADegenerateZeroWidthBandDoesNotDivideByZero() {
        let band = PriceBand(p25: 10, p50: 10, p75: 10)
        XCTAssertEqual(band.fit(10), 1.0, accuracy: 0.0001)
        XCTAssertEqual(band.fit(1000), 0.35, accuracy: 0.0001)
    }
}
