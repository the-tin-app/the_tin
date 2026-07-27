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

/// One line on the Supporters screen. Arrives on the catalog manifest — served, never compiled
/// in, so a name can be added or dropped without an App Store review cycle.
///
/// Recognition only: nothing in the app is unlocked by sponsorship, which is what keeps this
/// outside Apple's IAP rules. Anonymity is represented by ABSENCE — a sponsor who hasn't asked to
/// be listed simply isn't in the served list, so there is no "hidden" flag anyone can forget to
/// set. Decoding is total for the same reason `FundingSnapshot`'s is: a typo in the hand-curated
/// source must not throw and take the whole catalog update down with it.
struct Supporter: Codable, Equatable {
    let name: String
    let tier: String?
    let url: String?

    init(name: String, tier: String? = nil, url: String? = nil) {
        self.name = name
        self.tier = tier
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        url = try c.decodeIfPresent(String.self, forKey: .url)
    }

    /// Only https links are ever opened. The value is served data, so an arbitrary scheme
    /// reaching `openURL` would be a remote-controlled navigation on someone's phone.
    var link: URL? {
        guard let url, url.hasPrefix("https://") else { return nil }
        return URL(string: url)
    }
}

enum FundingModel {
    /// Compile-time switch for the support UI. `false` ships the "coming soon" variant (no
    /// meter, no donate link).
    ///
    /// The platform is settled — GitHub Sponsors, `AppConfig.supportURL` (Open Source Collective
    /// rejected the project 2026-07-25). Flip this to `true` only in a build where the listing is
    /// PUBLISHED and accepting money, and the nightly has actually run once with the GitHub-backed
    /// `refresh-funding.ts` on `main` + a rebuilt `catalog-pipeline:latest` image. Flipping early
    /// ships a meter reading "$0 of $150" to every user, which is worse than the coming-soon copy.
    static let isLive = false

    /// Fallback goal shown before the manifest's funding block has loaded ($150/mo).
    static let defaultGoalCents = 15_000

    /// Pure. Reads the goal from the manifest snapshot (falling back to `defaultGoalCents`),
    /// clamps the funded fraction, and never gates anything.
    static func display(from snapshot: FundingSnapshot?) -> FundingDisplay {
        let pct = snapshot.map { min(max($0.fundedPct, 0), 1) } ?? 0
        let goal = snapshot.flatMap { $0.monthlyGoalCents > 0 ? $0.monthlyGoalCents : nil } ?? defaultGoalCents
        return FundingDisplay(fundedPct: pct, monthlyGoalCents: goal, raisedCents: snapshot?.raisedCents ?? 0)
    }

    /// Pure. The served list, minus anything with no usable name — the source is hand-curated, and
    /// a blank row on a credits screen looks like a bug rather than the empty state it is.
    static func supporters(from list: [Supporter]?) -> [Supporter] {
        (list ?? []).filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Whole-dollar formatting for the goal/raised amounts (values are already dollar-grained).
    static func dollars(_ cents: Int) -> String { "$\(cents / 100)" }
}
