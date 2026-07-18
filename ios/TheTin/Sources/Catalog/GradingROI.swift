import Foundation

/// The "should I grade this card?" answer.
enum GradingVerdict: Equatable {
    case grade, borderline, keep
}

/// Pure grading-ROI math.
/// Every input already ships offline on every catalog tier — this is arithmetic, no I/O.
struct GradingROI: Equatable {
    /// How well an interpolated price is anchored by real ones.
    enum EstimateConfidence: Equatable { case high, medium, low }
    /// Whether a bucket's price is a recorded sale figure or our interpolation.
    enum PriceSource: Equatable { case actual, estimated(EstimateConfidence) }

    /// One populated grade: probability over the FULL PSA population × price (actual or estimated).
    struct Bucket: Equatable, Identifiable {
        let grade: Grade
        let probability: Double
        let price: Double
        let source: PriceSource
        var id: String { grade.rawValue }
        var isEstimate: Bool { source != .actual }
    }

    let buckets: [Bucket]        // descending grade order (psa10 first)
    let ev: Double               // Σ P(g) × price(g) over all populated grades
    let evNet: Double            // ev − fee − baseline (net expected gain over selling raw)
    let breakevenGrade: Grade?   // lowest populated grade where price − fee > baseline; nil = none
    let gemRate: Double?         // per-grader summary from the population feed, else computed
    let totalPopulation: Int     // Σ PSA row counts (the distribution's denominator)
    let lowConfidence: Bool      // totalPopulation < 50
    let verdict: GradingVerdict
    let playedWarning: Bool      // owned copy is MP or worse — played cards rarely gem
    var hasEstimates: Bool { buckets.contains(where: \.isEstimate) }

    /// PSA bulk-tier fee. Grading fees drift; the editable knob is the calibration.
    static let defaultFeeUsd = 21.99
    static let feeRange: ClosedRange<Double> = 0...500

    static func clampFee(_ fee: Double) -> Double {
        min(max(fee, feeRange.lowerBound), feeRange.upperBound)
    }

    /// Integer pop bucket for a display grade: floor, clamped 1...10 ("9.5" → 9, "8.5" → 8).
    /// Non-numeric pseudo-rows (auth/qualifiers/perfect/pristine) return nil.
    static func numericBucket(forDisplayGrade grade: String) -> Int? {
        guard let value = Double(grade), value >= 0.5 else { return nil }
        return min(max(Int(value.rounded(.down)), 1), 10)
    }

    /// Price for a grade from the actual anchors: the anchor itself when recorded; log-linear
    /// interpolation between the nearest anchors either side; flat at the boundary anchor
    /// outside the anchored range (no extrapolated curves). Anchors must be ascending by grade.
    static func interpolatedPrice(for numeric: Int,
                                  anchors: [(grade: Int, usd: Double)]) -> (usd: Double, source: PriceSource)? {
        if let exact = anchors.first(where: { $0.grade == numeric }) { return (exact.usd, .actual) }
        let lower = anchors.last { $0.grade < numeric }
        let upper = anchors.first { $0.grade > numeric }
        switch (lower, upper) {
        case let (lo?, hi?):
            let t = Double(numeric - lo.grade) / Double(hi.grade - lo.grade)
            let usd = exp(log(lo.usd) + t * (log(hi.usd) - log(lo.usd)))
            // Holdout validation (expert-v14, 2026-07-17): adjacent-anchored interpolation sits
            // at the eBay-median noise floor (~25-30% median error); it degrades with anchor gap.
            let gap = hi.grade - lo.grade
            let confidence: EstimateConfidence = gap <= 2 ? .high : (gap <= 4 ? .medium : .low)
            return (usd, .estimated(confidence))
        case let (lo?, nil): return (lo.usd, .estimated(.low))   // above highest anchor: hold flat
        case let (nil, hi?): return (hi.usd, .estimated(.low))   // below lowest anchor: hold flat
        case (nil, nil): return nil
        }
    }

    /// `nil` ⇒ hide the panel: no PSA population rows, no actually-priced grade to anchor on,
    /// or no baseline. `baseline` = what the copy sells for raw (owned copy's unit value, else
    /// NM market).
    static func compute(population: [PopulationRow], price: PriceRecord,
                        baseline: Double?, fee rawFee: Double,
                        ownedCondition: CardCondition? = nil) -> GradingROI? {
        // v1 economics are PSA-only (our prices are PSA); other graders' rows are ignored.
        let psaRows = population.filter { $0.grader.caseInsensitiveCompare("PSA") == .orderedSame }
        guard let baseline, !psaRows.isEmpty else { return nil }
        let fee = clampFee(rawFee)

        // Distribution over the FULL population — every graded copy counts, priced or not.
        var counts: [Int: Int] = [:]
        for row in psaRows {
            guard let numeric = numericBucket(forDisplayGrade: row.displayGrade) else { continue }
            counts[numeric, default: 0] += row.count
        }
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return nil }

        // Anchors = grades with a recorded price (log-linear needs strictly positive values).
        let anchors: [(grade: Int, usd: Double)] = Grade.allCases.compactMap { grade in
            guard let usd = price.gradedOnly(grade), usd > 0 else { return nil }
            return (grade.numeric, usd)
        }
        guard !anchors.isEmpty else { return nil }

        let buckets: [Bucket] = counts.keys.sorted(by: >).compactMap { numeric in
            guard let count = counts[numeric], count > 0,
                  let grade = Grade(numeric: numeric),
                  let priced = interpolatedPrice(for: numeric, anchors: anchors) else { return nil }
            return Bucket(grade: grade, probability: Double(count) / Double(total),
                          price: priced.usd, source: priced.source)
        }
        guard !buckets.isEmpty else { return nil }

        let ev = buckets.reduce(0) { $0 + $1.probability * $1.price }
        let evNet = ev - fee - baseline

        // Lowest populated grade whose (actual or estimated) price beats selling raw.
        let breakeven = buckets.reversed().first { $0.price - fee > baseline }?.grade

        let verdict: GradingVerdict
        if abs(evNet) < 0.2 * baseline {
            verdict = .borderline
        } else {
            verdict = evNet > 0 ? .grade : .keep
        }

        // Prefer the feed's per-grader summary; fall back to counting 10s ourselves.
        let gemRate = psaRows.first?.gemRate
            ?? counts[10].map { Double($0) / Double(total) }

        let played = ownedCondition.map { [.mp, .hp, .dmg].contains($0) } ?? false

        return GradingROI(buckets: buckets, ev: ev, evNet: evNet, breakevenGrade: breakeven,
                          gemRate: gemRate, totalPopulation: total,
                          lowConfidence: total < 50, verdict: verdict, playedWarning: played)
    }
}
