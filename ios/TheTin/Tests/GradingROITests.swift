import XCTest
@testable import TheTin

final class GradingROITests: XCTestCase {
    private func pop(_ grade: String, _ count: Int, grader: String = "PSA",
                     gemRate: Double? = nil) -> PopulationRow {
        PopulationRow(grader: grader, grade: grade, count: count, gemRate: gemRate, totalPopulation: nil)
    }

    /// Priced grades default to psa3 $5, psa7 $20, psa9 $50, psa10 $100 (easy mental math).
    private func price(psa3: Double? = 5, psa7: Double? = 20, psa9: Double? = 50,
                       psa10: Double? = 100) -> PriceRecord {
        PriceRecord(cardId: "c1", rawUsd: 30, rawEur: nil, psa3: psa3, psa7: psa7,
                    psa9: psa9, psa10: psa10, asOf: "2026-07-14")
    }

    // THE bug-report case: pop has more PSA 8 than PSA 7 but no psa8 price column. PSA 8 must
    // keep its own (larger) probability, priced by log-linear interpolation between 9 and 7 —
    // not fold into the 7 bucket, and not be renormalized away.
    func testPsa8MassStaysAtPsa8WithInterpolatedPrice() {
        let rows = [pop("10", 100), pop("9", 300), pop("8", 400), pop("7", 200)]
        let roi = GradingROI.compute(population: rows, price: price(psa3: nil),
                                     baseline: 30, fee: 20)!
        XCTAssertEqual(roi.totalPopulation, 1000)
        let p8 = roi.buckets.first { $0.grade == .psa8 }!
        XCTAssertEqual(p8.probability, 0.4)
        XCTAssertEqual(p8.price, (50.0 * 20.0).squareRoot(), accuracy: 0.001) // log-linear midpoint
        XCTAssertEqual(p8.source, .estimated(.high))                          // anchors adjacent (gap 2)
        XCTAssertTrue(roi.hasEstimates)
        XCTAssertEqual(roi.buckets.first { $0.grade == .psa9 }!.source, .actual)
        XCTAssertEqual(roi.buckets.map(\.probability).reduce(0, +), 1.0, accuracy: 1e-9)
        XCTAssertEqual(roi.buckets.map(\.grade), [.psa10, .psa9, .psa8, .psa7]) // descending display order
    }

    func testHalfGradesFloorAndPseudoRowsExcluded() {
        // "g10" / "9_5" exercise displayGrade normalization (REST vs bulk-export forms);
        // auth/qualifiers are pseudo-rows, never part of the distribution.
        let rows = [pop("g10", 10), pop("9_5", 5), pop("8.5", 7),
                    pop("auth", 99), pop("qualifiers", 3)]
        let roi = GradingROI.compute(population: rows, price: price(), baseline: 30, fee: 20)!
        XCTAssertEqual(roi.totalPopulation, 22)   // 10 + 5(→9) + 7(→8)
        XCTAssertEqual(roi.buckets.first { $0.grade == .psa9 }!.probability, 5.0 / 22, accuracy: 1e-9)
    }

    func testHoldFlatOutsideAnchorsIsLowConfidence() {
        // Below the lowest anchor (psa7 when psa3 is nil) prices hold flat, marked rough.
        let rows = [pop("10", 60), pop("2", 40)]
        let roi = GradingROI.compute(population: rows, price: price(psa3: nil),
                                     baseline: 5, fee: 20)!
        let p2 = roi.buckets.first { $0.grade == .psa2 }!
        XCTAssertEqual(p2.price, 20)                 // flat at lowest anchor (psa7 $20)
        XCTAssertEqual(p2.source, .estimated(.low))
        // Above the highest anchor: psa10 count with only psa9-and-below priced.
        let roiTop = GradingROI.compute(population: [pop("10", 50), pop("9", 50)],
                                        price: price(psa10: nil), baseline: 5, fee: 20)!
        let p10 = roiTop.buckets.first { $0.grade == .psa10 }!
        XCTAssertEqual(p10.price, 50)                // flat at highest anchor (psa9 $50)
        XCTAssertEqual(p10.source, .estimated(.low))
    }

    func testDistantAnchorsLowerConfidence() {
        // psa5 between anchors 3 and 7 (gap 4) → medium; wider than 4 → low.
        let rows = [pop("5", 100)]
        let roi = GradingROI.compute(population: rows, price: price(), baseline: 5, fee: 20)!
        XCTAssertEqual(roi.buckets.first { $0.grade == .psa5 }!.source, .estimated(.medium))
        let wide = GradingROI.compute(population: [pop("5", 100)],
                                      price: price(psa3: nil, psa7: nil), baseline: 5, fee: 20)!
        // anchors 9,10 only → psa5 below lowest → hold flat, low.
        XCTAssertEqual(wide.buckets.first { $0.grade == .psa5 }!.source, .estimated(.low))
    }

    func testExpectedValueOverFullDistribution() {
        let rows = [pop("10", 400), pop("9", 300), pop("7", 200), pop("3", 100)]
        let roi = GradingROI.compute(population: rows, price: price(), baseline: 30, fee: 20)!
        // EV = .4×100 + .3×50 + .2×20 + .1×5 = 59.5; evNet = EV − fee − baseline.
        XCTAssertEqual(roi.ev, 59.5, accuracy: 1e-9)
        XCTAssertEqual(roi.evNet, 9.5, accuracy: 1e-9)
        XCTAssertFalse(roi.hasEstimates)   // every populated grade has a real price
    }

    func testHidesPanelWithoutAnyActualPriceOrPsaRowsOrBaseline() {
        let rows = [pop("10", 500), pop("9", 400)]
        XCTAssertNil(GradingROI.compute(population: rows,
                                        price: price(psa3: nil, psa7: nil, psa9: nil, psa10: nil),
                                        baseline: 30, fee: 20))
        XCTAssertNil(GradingROI.compute(population: [pop("10", 500, grader: "CGC")],
                                        price: price(), baseline: 30, fee: 20))
        XCTAssertNil(GradingROI.compute(population: rows, price: price(), baseline: nil, fee: 20))
    }

    func testBreakevenGrade() {
        let rows = [pop("10", 500), pop("9", 500)]
        // Breakeven = LOWEST populated grade whose bucket price − fee > baseline (strict).
        // baseline 30, fee 20 → needs price > 50: psa9 ($50 − 20 = 30, not >) misses; psa10 clears.
        XCTAssertEqual(GradingROI.compute(population: rows, price: price(),
                                          baseline: 30, fee: 20)!.breakevenGrade, .psa10)
        // fee 10 → psa9 ($50 − 10 = 40 > 30) clears and is lower than psa10 → psa9.
        XCTAssertEqual(GradingROI.compute(population: rows, price: price(),
                                          baseline: 30, fee: 10)!.breakevenGrade, .psa9)
        // Baseline above every graded price − fee → no grade beats selling raw.
        XCTAssertNil(GradingROI.compute(population: rows, price: price(),
                                        baseline: 500, fee: 20)!.breakevenGrade)
    }

    func testVerdictThresholds() {
        let rows = [pop("10", 400), pop("9", 300), pop("7", 200), pop("3", 100)]  // EV = 59.5
        // baseline 30 → borderline band is |evNet| < 6 (20% of baseline).
        func verdict(fee: Double) -> GradingVerdict {
            GradingROI.compute(population: rows, price: price(), baseline: 30, fee: fee)!.verdict
        }
        XCTAssertEqual(verdict(fee: 20), .grade)        // evNet = +9.5
        XCTAssertEqual(verdict(fee: 25), .borderline)   // evNet = +4.5, inside the band
        XCTAssertEqual(verdict(fee: 33), .borderline)   // evNet = −3.5, band is symmetric
        XCTAssertEqual(verdict(fee: 45), .keep)         // evNet = −15.5
    }

    func testConfidenceGate() {
        let small = [pop("10", 30), pop("9", 19)]    // 49 < 50 → low confidence
        XCTAssertTrue(GradingROI.compute(population: small, price: price(),
                                         baseline: 30, fee: 20)!.lowConfidence)
        let enough = [pop("10", 30), pop("9", 20)]   // exactly 50 → confident (spec says "< 50")
        XCTAssertFalse(GradingROI.compute(population: enough, price: price(),
                                          baseline: 30, fee: 20)!.lowConfidence)
    }

    func testGemRateFallbackCountsTens() {
        let rows = [pop("10", 250), pop("9", 750)]
        let roi = GradingROI.compute(population: rows, price: price(), baseline: 30, fee: 20)!
        XCTAssertEqual(roi.gemRate!, 0.25, accuracy: 1e-9)   // no feed gemRate → count-based
    }

    func testPlayedConditionWarningTrigger() {
        let rows = [pop("10", 500), pop("9", 500)]
        func warns(_ cond: CardCondition?) -> Bool {
            GradingROI.compute(population: rows, price: price(), baseline: 30, fee: 20,
                               ownedCondition: cond)!.playedWarning
        }
        XCTAssertTrue(warns(.mp))    // MP or worse triggers the stronger warning
        XCTAssertTrue(warns(.hp))
        XCTAssertTrue(warns(.dmg))
        XCTAssertFalse(warns(.lp))   // NM/LP and "not owned" don't
        XCTAssertFalse(warns(nil))
    }
}
