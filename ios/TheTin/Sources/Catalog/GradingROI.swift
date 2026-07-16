import Foundation

/// The "should I grade this card?" answer.
enum GradingVerdict: Equatable {
    case grade, borderline, keep
}

/// Pure grading-ROI math.
/// Every input already ships offline on every catalog tier — this is arithmetic, no I/O.
struct GradingROI: Equatable {
    /// One priced grade bucket: probability (renormalized over priced buckets) × PSA price.
    struct Bucket: Equatable, Identifiable {
        let grade: Grade
        let probability: Double
        let price: Double
        var id: String { grade.rawValue }
    }

    let buckets: [Bucket]        // descending grade order (psa10 first)
    let ev: Double               // Σ P(g) × price(g) over priced buckets
    let evNet: Double            // ev − fee − baseline (net expected gain over selling raw)
    let breakevenGrade: Grade?   // lowest priced grade where price − fee > baseline; nil = none
    let gemRate: Double?         // per-grader summary from the population feed, else computed
    let totalPopulation: Int     // Σ PSA row counts (the distribution's denominator)
    let lowConfidence: Bool      // totalPopulation < 50
    let verdict: GradingVerdict
    let playedWarning: Bool      // owned copy is MP or worse — played cards rarely gem

    /// PSA bulk-tier fee. Grading fees drift; the editable knob is the calibration.
    static let defaultFeeUsd = 21.99
    static let feeRange: ClosedRange<Double> = 0...500

    static func clampFee(_ fee: Double) -> Double {
        min(max(fee, feeRange.lowerBound), feeRange.upperBound)
    }

    /// Population grade → nearest priced grade at or below it (conservative by construction):
    /// 10 → psa10, 9/9.5 → psa9, 7/7.5/8/8.5 → psa7, everything ≤ 6.5 → psa3.
    /// Expects a `PopulationRow.displayGrade` string; non-numeric grades don't map.
    static func bucket(forDisplayGrade grade: String) -> Grade? {
        guard let value = Double(grade) else { return nil }
        switch value {
        case 10...:   return .psa10
        case 9..<10:  return .psa9
        case 7..<9:   return .psa7
        default:      return .psa3
        }
    }

    /// `nil` ⇒ hide the panel: no PSA population rows, no priced grade buckets, or no baseline.
    /// `baseline` = what the copy sells for raw (owned copy's unit value, else NM market).
    static func compute(population: [PopulationRow], price: PriceRecord,
                        baseline: Double?, fee rawFee: Double,
                        ownedCondition: CardCondition? = nil) -> GradingROI? {
        // v1 economics are PSA-only (our prices are PSA); other graders' rows are ignored.
        let psaRows = population.filter { $0.grader.caseInsensitiveCompare("PSA") == .orderedSame }
        guard let baseline, !psaRows.isEmpty else { return nil }
        let fee = clampFee(rawFee)

        var counts: [Grade: Int] = [:]
        for row in psaRows {
            guard let grade = bucket(forDisplayGrade: row.displayGrade) else { continue }
            counts[grade, default: 0] += row.count
        }
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return nil }

        // Keep only buckets whose mapped price column is non-null; renormalize over them so the
        // probabilities still sum to 1 (skipping a null column, per spec).
        let priced: [(grade: Grade, count: Int, usd: Double)] =
            [Grade.psa10, .psa9, .psa7, .psa3].compactMap { grade in
                guard let count = counts[grade], count > 0,
                      let usd = price.gradedOnly(grade) else { return nil }
                return (grade, count, usd)
            }
        let pricedTotal = priced.reduce(0) { $0 + $1.count }
        guard pricedTotal > 0 else { return nil }

        let buckets = priced.map {
            Bucket(grade: $0.grade, probability: Double($0.count) / Double(pricedTotal), price: $0.usd)
        }
        let ev = buckets.reduce(0) { $0 + $1.probability * $1.price }
        let evNet = ev - fee - baseline

        // Lowest priced grade that beats selling raw. Grade.allCases is declared ascending
        // (psa3, psa7, psa9, psa10), so `first` is the lowest.
        let breakeven = Grade.allCases.first { grade in
            guard let usd = price.gradedOnly(grade) else { return false }
            return usd - fee > baseline
        }

        let verdict: GradingVerdict
        if abs(evNet) < 0.2 * baseline {
            verdict = .borderline
        } else {
            verdict = evNet > 0 ? .grade : .keep
        }

        // Prefer the feed's per-grader summary; fall back to counting 10s ourselves.
        let gemRate = psaRows.first?.gemRate
            ?? counts[.psa10].map { Double($0) / Double(total) }

        let played = ownedCondition.map { [.mp, .hp, .dmg].contains($0) } ?? false

        return GradingROI(buckets: buckets, ev: ev, evNet: evNet, breakevenGrade: breakeven,
                          gemRate: gemRate, totalPopulation: total,
                          lowConfidence: total < 50, verdict: verdict, playedWarning: played)
    }
}
