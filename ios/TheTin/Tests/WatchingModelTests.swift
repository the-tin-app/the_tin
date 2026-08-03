import XCTest
@testable import TheTin

/// The Watching screen's section rules. Only the decisions are tested here — the queries behind
/// them are `CatalogStore`'s, already covered, and a section that is purely "run this query" has
/// nothing of its own to get wrong.
final class WatchingModelTests: XCTestCase {

    /// Drops exclude hunted cards. A hunted card leads the screen already; repeating it four
    /// rows down as "biggest drop" says the same thing twice.
    func testDropsExcludeHuntedCards() {
        let entries = [
            "hunted": WantEntry(targetUsd: 100, hunt: Hunt(minCondition: .nm)),
            "plain": WantEntry(targetUsd: 100),
        ]
        XCTAssertEqual(WatchingModel.dropCandidateIds(entries: entries), ["plain"])
    }

    /// Only real drops, and capped so the section stays a summary rather than a second wishlist.
    /// The threshold is Discover's, reused rather than redefined.
    func testDropsAreThresholdedAndCapped() {
        let pcts = ["a": -0.30, "b": -0.25, "c": -0.20, "d": -0.15, "e": -0.12,
                    "f": -0.11, "g": -0.02]
        let kept = WatchingModel.rankedDrops(pct7dById: pcts)
        XCTAssertEqual(kept.count, 5)
        XCTAssertEqual(kept.first, "a", "biggest drop leads")
        XCTAssertFalse(kept.contains("g"), "-2% is not a drop")
    }

    /// ⚠️ Fractions, not whole percent. A -12% drop is -0.12; the old whole-percent reading of
    /// this column is what made Discover's Deals filter dead (see `DiscoverConstants`).
    func testTheDropThresholdIsAFractionNotWholePercent() {
        XCTAssertEqual(WatchingModel.rankedDrops(pct7dById: ["a": -0.06]), ["a"])
        XCTAssertTrue(WatchingModel.rankedDrops(pct7dById: ["a": -0.04]).isEmpty)
    }

    /// A rise is never a "drop", however large.
    func testRisesAreNeverDrops() {
        XCTAssertTrue(WatchingModel.rankedDrops(pct7dById: ["a": 0.40]).isEmpty)
    }

    /// A weekly series summarised as "up N of the last M weeks" over a fixed 8-week window,
    /// with the percentage measured across that same window so the sentence and the number
    /// describe one span.
    func testGrailTrendCountsRisingWeeksInAnEightWeekWindow() throws {
        let rising = (0..<9).map { Double(100 + $0 * 5) }   // 9 points ⇒ 8 steps, all up
        let trend = try XCTUnwrap(WatchingModel.trend(weeklyUsd: rising))
        XCTAssertEqual(trend.upWeeks, 8)
        XCTAssertEqual(trend.totalWeeks, 8)
        XCTAssertEqual(trend.pct, (140.0 - 100.0) / 100.0, accuracy: 0.0001)
    }

    /// Longer history is windowed, not averaged over everything — this section is the long view,
    /// but "the last 8 weeks" has to mean the last 8.
    func testTrendUsesOnlyTheMostRecentWindow() throws {
        let series = Array(repeating: 10.0, count: 20) + (0..<9).map { Double(100 + $0 * 5) }
        let trend = try XCTUnwrap(WatchingModel.trend(weeklyUsd: series))
        XCTAssertEqual(trend.totalWeeks, 8)
        XCTAssertEqual(trend.upWeeks, 8)
    }

    /// Not enough history is no trend at all — the section hides rather than drawing a flat line
    /// that reads as real. This is every card on the casual tier, which is every simulator.
    func testTooLittleHistoryIsNoTrend() {
        XCTAssertNil(WatchingModel.trend(weeklyUsd: [100]), "one point is not a trend")
        XCTAssertNil(WatchingModel.trend(weeklyUsd: []), "casual tier: no history at all")
    }

    /// A zero opening price can't produce a percentage — guard rather than divide.
    func testAZeroBaseIsNoTrend() {
        XCTAssertNil(WatchingModel.trend(weeklyUsd: [0, 10, 20]))
    }

    /// The dot means "there is data here you haven't seen", not "you own things" — a comparison
    /// of the catalog's price date against the one stored on the last visit. A count was
    /// rejected: with no event log there is nothing to count that wouldn't be permanent state.
    func testDotShowsOnlyForPriceDataNewerThanYourLastVisit() {
        XCTAssertTrue(WatchingModel.hasUnseen(asOf: "2026-08-01", lastSeen: "2026-07-31"))
        XCTAssertFalse(WatchingModel.hasUnseen(asOf: "2026-08-01", lastSeen: "2026-08-01"))
        XCTAssertFalse(WatchingModel.hasUnseen(asOf: "2026-07-30", lastSeen: "2026-08-01"),
                       "an older catalog is not news")
    }

    func testFirstVisitShowsTheDot() {
        XCTAssertTrue(WatchingModel.hasUnseen(asOf: "2026-08-01", lastSeen: nil))
    }

    /// No catalog date at all (catalog missing or still downloading) is not news.
    func testNoCatalogDateNoDot() {
        XCTAssertFalse(WatchingModel.hasUnseen(asOf: nil, lastSeen: nil))
        XCTAssertFalse(WatchingModel.hasUnseen(asOf: nil, lastSeen: "2026-08-01"))
    }
}
