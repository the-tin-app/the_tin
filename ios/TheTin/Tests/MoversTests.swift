import XCTest
@testable import TheTin

final class MoversTests: XCTestCase {
    private func entry(_ id: String, card: String, qty: Int = 1, grade: String? = nil,
                       condition: String = "NM") -> CollectionEntry {
        CollectionEntry(id: id, cardId: card, groupId: "g1", qty: qty, condition: condition,
                        grade: grade, pricePaid: nil, acquiredAt: nil, acquiredFrom: nil,
                        addedAt: Date(timeIntervalSince1970: 0), variant: nil)
    }

    private func price(_ card: String, raw: Double? = nil, psa10: Double? = nil) -> PriceRecord {
        PriceRecord(cardId: card, rawUsd: raw, rawEur: nil, psa3: nil, psa7: nil, psa9: nil,
                    psa10: psa10, asOf: "2026-07-24")
    }

    private func raw(_ pct: Double) -> DeltaRecord {
        DeltaRecord(kind: .raw, key: "", pct1d: pct, pct7d: pct * 2, pct30d: nil)
    }

    /// Impact is measured against the EARLIER price: a holding now worth $104 after a +4% move
    /// gained $4, not $4.16. `value × pct` would overstate every gain and understate every loss.
    func testImpactIsMeasuredAgainstTheEarlierPrice() {
        let s = Movers.summary(entries: [entry("e", card: "c1", qty: 2)],
                               prices: ["c1": price("c1", raw: 52)],
                               deltasByCard: ["c1": [raw(0.04)]],
                               period: .d1)
        XCTAssertEqual(s.rows.count, 1)
        // now = 2 × 52 = 104; before = 104 / 1.04 = 100; impact = 4
        XCTAssertEqual(s.rows[0].value, 104, accuracy: 0.0001)
        XCTAssertEqual(s.rows[0].impact, 4, accuracy: 0.0001)
        XCTAssertEqual(s.totalImpact, 4, accuracy: 0.0001)
        XCTAssertEqual(s.rows[0].pct ?? 0, 0.04, accuracy: 0.0001)
    }

    /// Dollar impact, not raw percent: a big holding moving a little outranks a cheap card that
    /// doubled. This is the whole reason the screen exists.
    func testRowsSortByDollarImpactNotPercent() {
        let entries = [entry("a", card: "chase", qty: 2), entry("b", card: "common", qty: 1)]
        let prices = ["chase": price("chase", raw: 300), "common": price("common", raw: 0.80)]
        let deltas = ["chase": [raw(0.04)], "common": [raw(1.0)]]   // +4% vs +100%
        let s = Movers.summary(entries: entries, prices: prices, deltasByCard: deltas, period: .d1)
        XCTAssertEqual(s.rows.map(\.cardId), ["chase", "common"])
        XCTAssertGreaterThan(s.rows[0].impact, s.rows[1].impact)
    }

    /// Losers are ranked by magnitude alongside gainers — a big drop is exactly as much "news"
    /// as a big rise, and burying it under every small gain hides the thing you'd act on.
    func testLosersRankByMagnitudeAlongsideGainers() {
        let entries = [entry("a", card: "up", qty: 1), entry("b", card: "down", qty: 1)]
        let prices = ["up": price("up", raw: 10), "down": price("down", raw: 90)]
        let deltas = ["up": [raw(0.10)], "down": [raw(-0.10)]]
        let s = Movers.summary(entries: entries, prices: prices, deltasByCard: deltas, period: .d1)
        XCTAssertEqual(s.rows.first?.cardId, "down")
        XCTAssertLessThan(s.rows[0].impact, 0)
        XCTAssertLessThan(s.totalImpact, 0)
    }

    /// Rows are per card: a raw copy and a graded copy move on different price series but read as
    /// one card, with one aggregate percentage derived back out of the money.
    func testCopiesOfOneCardAggregateIntoASingleRow() {
        let entries = [entry("raw", card: "c1", qty: 1),
                       entry("slab", card: "c1", qty: 1, grade: "psa10")]
        let prices = ["c1": price("c1", raw: 100, psa10: 900)]
        let deltas = ["c1": [DeltaRecord(kind: .raw, key: "", pct1d: 0.10, pct7d: nil, pct30d: nil),
                             DeltaRecord(kind: .psa, key: "10", pct1d: 0.0, pct7d: nil, pct30d: nil)]]
        let s = Movers.summary(entries: entries, prices: prices, deltasByCard: deltas, period: .d1)
        XCTAssertEqual(s.rows.count, 1)
        XCTAssertEqual(s.rows[0].qty, 2)
        XCTAssertEqual(s.rows[0].value, 1000, accuracy: 0.0001)
        // Only the raw copy moved: 100 − 100/1.1 = 9.0909…
        XCTAssertEqual(s.rows[0].impact, 100 - 100 / 1.1, accuracy: 0.0001)
    }

    /// A graded copy must report ITS grade's change, not the raw market's — the same ladder
    /// `GroupStats.unitDelta` walks for the value.
    func testGradedCopyUsesItsGradeChangeNotRaw() {
        let entries = [entry("slab", card: "c1", qty: 1, grade: "psa10")]
        let prices = ["c1": price("c1", raw: 100, psa10: 1000)]
        let deltas = ["c1": [DeltaRecord(kind: .raw, key: "", pct1d: 0.50, pct7d: nil, pct30d: nil),
                             DeltaRecord(kind: .psa, key: "10", pct1d: 0.25, pct7d: nil, pct30d: nil)]]
        let s = Movers.summary(entries: entries, prices: prices, deltasByCard: deltas, period: .d1)
        XCTAssertEqual(s.rows[0].impact, 1000 - 1000 / 1.25, accuracy: 0.0001)
    }

    /// A copy the catalog can't price EXACTLY is not a mover.
    ///
    /// Reported from device 2026-07-26: a card held only as DMG, with no DMG price, appeared in
    /// Movers valued at the raw market price — and therefore quoting the RAW market's move for a
    /// damaged card. `entryValue` walks a fallback ladder by design (the tin total is an
    /// acknowledged estimate); Movers claims "this card moved your tin by $X", which an estimate
    /// on the wrong rung makes false.
    func testCopyWithNoPriceForItsConditionIsNotAMover() {
        let entries = [entry("dmg", card: "c1", condition: "DMG")]
        let prices = ["c1": price("c1", raw: 100)]
        let deltas = ["c1": [raw(0.20)]]
        // NM is priced, DMG is not — the played copy has no price of its own.
        let conditions = ["c1": [ConditionPrice(condition: .nearMint, usd: 100)]]
        let s = Movers.summary(entries: entries, prices: prices, deltasByCard: deltas,
                               conditionsByCard: conditions, period: .d1)
        XCTAssertTrue(s.rows.isEmpty, "a DMG copy with no DMG price must not report the raw move")
        XCTAssertEqual(s.cardsWithData, 0)
        XCTAssertEqual(s.totalCards, 1, "it's still a card you own — just not one we can price")

        // Same card, same everything, but now DMG IS priced: it belongs in the list, at its own
        // price and its own change.
        let priced = ["c1": [ConditionPrice(condition: .nearMint, usd: 100),
                             ConditionPrice(condition: .damaged, usd: 10)]]
        let ok = Movers.summary(entries: entries, prices: prices, deltasByCard: deltas,
                                conditionsByCard: priced, period: .d1)
        XCTAssertEqual(ok.rows.count, 1)
        XCTAssertEqual(ok.rows[0].value, 10, accuracy: 0.0001)
    }

    func testPeriodSelectsTheMatchingColumn() {
        let entries = [entry("e", card: "c1", qty: 1)]
        let prices = ["c1": price("c1", raw: 100)]
        let deltas = ["c1": [raw(0.10)]]   // 1d = 10%, 7d = 20%, 30d = nil
        XCTAssertEqual(Movers.summary(entries: entries, prices: prices, deltasByCard: deltas,
                                      period: .d7).rows.first?.impact ?? 0,
                       100 - 100 / 1.2, accuracy: 0.0001)
        // A window the row has no data for contributes nothing at all, rather than reading as 0%.
        let thirty = Movers.summary(entries: entries, prices: prices, deltasByCard: deltas, period: .d30)
        XCTAssertTrue(thirty.rows.isEmpty)
        XCTAssertEqual(thirty.cardsWithData, 0)
        XCTAssertEqual(thirty.totalCards, 1)
    }

    /// Coverage is the honest denominator for "based on N of M cards": a card with no change data
    /// still counts as owned.
    func testCoverageCountsOwnedCardsWithoutChangeData() {
        let entries = [entry("a", card: "moved"), entry("b", card: "quiet")]
        let prices = ["moved": price("moved", raw: 10), "quiet": price("quiet", raw: 10)]
        let s = Movers.summary(entries: entries, prices: prices,
                               deltasByCard: ["moved": [raw(0.10)]], period: .d1)
        XCTAssertEqual(s.cardsWithData, 1)
        XCTAssertEqual(s.totalCards, 2)
    }

    /// Sub-cent moves are rounding noise and would render as a list of "$0.00" rows that say
    /// nothing — they're excluded from the rows but still counted as covered.
    func testSubCentMovesAreNotListed() {
        let s = Movers.summary(entries: [entry("e", card: "c1", qty: 1)],
                               prices: ["c1": price("c1", raw: 0.10)],
                               deltasByCard: ["c1": [raw(0.001)]],
                               period: .d1)
        XCTAssertTrue(s.rows.isEmpty)
        XCTAssertEqual(s.cardsWithData, 1)
    }

    func testUnpricedCardContributesNothing() {
        let s = Movers.summary(entries: [entry("e", card: "c1", qty: 1)],
                               prices: [:], deltasByCard: ["c1": [raw(0.50)]], period: .d1)
        XCTAssertTrue(s.rows.isEmpty)
        XCTAssertEqual(s.totalImpact, 0)
        XCTAssertEqual(s.totalCards, 1)
    }

    /// Basis-flip guard. `price_latest.raw_usd` can quote a different printing than it did in
    /// yesterday's artifact, and the resulting "change" is the spread between two printings — a
    /// card showed +1800% while its own detail screen said +0.2% (2026-07-25). Better to omit the
    /// card than to claim the tin gained eighteen times over.
    func testImplausibleChangesAreOmittedRatherThanShown() {
        let s = Movers.summary(entries: [entry("e", card: "c1", qty: 1)],
                               prices: ["c1": price("c1", raw: 500)],
                               deltasByCard: ["c1": [raw(18.0)]],   // +1800%
                               period: .d1)
        XCTAssertTrue(s.rows.isEmpty)
        XCTAssertEqual(s.totalImpact, 0, "a basis flip must not move the headline either")
    }

    /// The guard is a ceiling on nonsense, not on the market: a card that genuinely doubled is
    /// still reported.
    func testALegitimateDoublingIsStillReported() {
        let s = Movers.summary(entries: [entry("e", card: "c1", qty: 1)],
                               prices: ["c1": price("c1", raw: 200)],
                               deltasByCard: ["c1": [raw(1.0)]],    // +100%
                               period: .d1)
        XCTAssertEqual(s.rows.count, 1)
        XCTAssertEqual(s.rows[0].impact, 100, accuracy: 0.001)
    }

    func testEmptyTinIsEmptySummary() {
        let s = Movers.summary(entries: [], prices: [:], deltasByCard: [:], period: .d1)
        XCTAssertTrue(s.rows.isEmpty)
        XCTAssertEqual(s.totalImpact, 0)
        XCTAssertEqual(s.totalCards, 0)
    }
}
