import Foundation

/// Mirrors the frozen backend `manifest.funding` block. Lenient: an unknown/missing `state`
/// string decodes to `.unknown` and decoding NEVER throws on an unrecognized state.
struct FundingSnapshot: Codable, Equatable {
    let state: FundingState
    let fundedPct: Double
    let monthlyGoalCents: Int
    let raisedCents: Int
    let updatedAt: String   // ISO8601, e.g. "2026-07-06T09:00:00.000Z"

    private enum CodingKeys: String, CodingKey {
        case state, fundedPct, monthlyGoalCents, raisedCents, updatedAt
    }

    /// Memberwise init retained alongside the custom decoder below (which would otherwise
    /// suppress it) so callers — e.g. tests building manifest fixtures — can construct a
    /// snapshot directly instead of round-tripping through JSON.
    init(state: FundingState, fundedPct: Double, monthlyGoalCents: Int, raisedCents: Int, updatedAt: String) {
        self.state = state
        self.fundedPct = fundedPct
        self.monthlyGoalCents = monthlyGoalCents
        self.raisedCents = raisedCents
        self.updatedAt = updatedAt
    }

    /// Total decode: any subset of keys (including none) yields a valid snapshot. Mirrors the
    /// frozen contract that a missing/unrecognized `state` is `.unknown` and decoding never
    /// throws — including when the `"state"` key itself is entirely absent.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawState = try container.decodeIfPresent(String.self, forKey: .state)
        state = FundingState.from(raw: rawState)
        fundedPct = try container.decodeIfPresent(Double.self, forKey: .fundedPct) ?? 0
        monthlyGoalCents = try container.decodeIfPresent(Int.self, forKey: .monthlyGoalCents) ?? 0
        raisedCents = try container.decodeIfPresent(Int.self, forKey: .raisedCents) ?? 0
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

/// Display-only funding progress. Purely informational — prices always update regardless of
/// funding, so there is no gate, no punishment, and no "state" copy. It drives the always-on
/// support bar + Settings section, and a non-interactive progress meter toward the monthly goal.
struct FundingDisplay: Equatable {
    let fundedPct: Double      // clamped 0…1
    let monthlyGoalCents: Int  // e.g. 15000 = $150/mo
    let raisedCents: Int
}

enum FundingModel {
    /// Fallback goal shown before the manifest's funding block has loaded ($150/mo).
    static let defaultGoalCents = 15_000

    /// Pure. Reads the goal from the manifest snapshot (falling back to `defaultGoalCents`),
    /// clamps the funded fraction, and never gates anything.
    static func display(from snapshot: FundingSnapshot?) -> FundingDisplay {
        let pct = snapshot.map { min(max($0.fundedPct, 0), 1) } ?? 0
        let goal = snapshot.flatMap { $0.monthlyGoalCents > 0 ? $0.monthlyGoalCents : nil } ?? defaultGoalCents
        return FundingDisplay(fundedPct: pct, monthlyGoalCents: goal, raisedCents: snapshot?.raisedCents ?? 0)
    }

    /// Whole-dollar formatting for the goal/raised amounts (values are already dollar-grained).
    static func dollars(_ cents: Int) -> String { "$\(cents / 100)" }
}
