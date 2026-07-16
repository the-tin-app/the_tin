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

    // Spec: half grades map to the nearest priced grade at or below (10→psa10, 9/9.5→psa9,
    // 7–8.5→psa7, ≤6.5→psa3); PSA rows only; unpriced buckets dropped and the rest renormalized.
    func testDistributionMapsHalfGradesAndRenormalizesUnpricedBuckets() {
        // "g10" and "9_5" exercise displayGrade normalization (REST vs bulk-export ingest forms).
        let rows = [pop("10", 300), pop("g10", 100),          // psa10: 400
                    pop("9_5", 100), pop("9", 200),           // psa9:  300
                    pop("8.5", 100), pop("7", 100),           // psa7:  200
                    pop("6.5", 50), pop("1", 50),             // psa3:  100
                    pop("10", 9999, grader: "CGC")]           // ignored: PSA only
        let roi = GradingROI.compute(population: rows, price: price(), baseline: 30, fee: 20)!
        XCTAssertEqual(roi.totalPopulation, 1000)
        XCTAssertEqual(roi.buckets.map(\.grade), [.psa10, .psa9, .psa7, .psa3])
        XCTAssertEqual(roi.buckets.map(\.probability), [400.0/1000, 300.0/1000, 200.0/1000, 100.0/1000])

        // psa3 price null → its bucket is dropped and the rest renormalize over 900.
        let renorm = GradingROI.compute(population: rows, price: price(psa3: nil), baseline: 30, fee: 20)!
        XCTAssertEqual(renorm.buckets.map(\.grade), [.psa10, .psa9, .psa7])
        XCTAssertEqual(renorm.buckets.map(\.probability), [400.0/900, 300.0/900, 200.0/900])

        // Degenerate renormalizations hide the panel: all graded prices null, or no PSA rows.
        XCTAssertNil(GradingROI.compute(population: rows,
                                        price: price(psa3: nil, psa7: nil, psa9: nil, psa10: nil),
                                        baseline: 30, fee: 20))
        XCTAssertNil(GradingROI.compute(population: [pop("10", 500, grader: "CGC")],
                                        price: price(), baseline: 30, fee: 20))
    }

    func testExpectedValue() {
        let rows = [pop("10", 400), pop("9", 300), pop("8", 200), pop("7", 50),
                    pop("6", 30), pop("1", 20)]   // psa10 .4, psa9 .3, psa7 .25, psa3 .05
        let roi = GradingROI.compute(population: rows, price: price(), baseline: 30, fee: 20)!
        // EV = .4×100 + .3×50 + .25×20 + .05×5 = 60.25; evNet = EV − fee − baseline.
        XCTAssertEqual(roi.ev, 60.25, accuracy: 1e-9)
        XCTAssertEqual(roi.evNet, 10.25, accuracy: 1e-9)
    }

    func testBreakevenGrade() {
        let rows = [pop("10", 500), pop("9", 500)]
        // Breakeven = LOWEST priced grade where price − fee > baseline (strict).
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
        let rows = [pop("10", 400), pop("9", 300), pop("8", 200), pop("7", 50),
                    pop("6", 30), pop("1", 20)]   // EV = 60.25 (see testExpectedValue)
        // baseline 30 → borderline band is |evNet| < 6 (20% of baseline).
        func verdict(fee: Double) -> GradingVerdict {
            GradingROI.compute(population: rows, price: price(), baseline: 30, fee: fee)!.verdict
        }
        XCTAssertEqual(verdict(fee: 20), .grade)        // evNet = +10.25
        XCTAssertEqual(verdict(fee: 26), .borderline)   // evNet = +4.25, inside the band
        XCTAssertEqual(verdict(fee: 33), .borderline)   // evNet = −2.75, band is symmetric
        XCTAssertEqual(verdict(fee: 45), .keep)         // evNet = −14.75
    }

    func testConfidenceGate() {
        let small = [pop("10", 30), pop("9", 19)]    // 49 < 50 → low confidence
        XCTAssertTrue(GradingROI.compute(population: small, price: price(),
                                         baseline: 30, fee: 20)!.lowConfidence)
        let enough = [pop("10", 30), pop("9", 20)]   // exactly 50 → confident (spec says "< 50")
        XCTAssertFalse(GradingROI.compute(population: enough, price: price(),
                                          baseline: 30, fee: 20)!.lowConfidence)
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
