import XCTest
@testable import TheTin

/// The two price lines a collector states at first run, and the three intentions they create.
final class ForYouSeedTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let tiers = PriceTiers(routineCeiling: 10, occasionalCeiling: 60)

    private func entry(_ id: String, paid: Double?) -> CollectionEntry {
        CollectionEntry(id: UUID().uuidString, cardId: id, groupId: "", qty: 1,
                        condition: nil, grade: nil, pricePaid: paid, acquiredAt: now,
                        acquiredFrom: nil, addedAt: now)
    }

    // MARK: which intention a price falls under

    func testEveryPriceLandsInExactlyOneTier() {
        XCTAssertEqual(tiers.tier(for: 0.50), .routine)
        XCTAssertEqual(tiers.tier(for: 10), .routine, "the line itself is inclusive")
        XCTAssertEqual(tiers.tier(for: 10.01), .occasional)
        XCTAssertEqual(tiers.tier(for: 60), .occasional)
        XCTAssertEqual(tiers.tier(for: 60.01), .someday)
        XCTAssertEqual(tiers.tier(for: 4500), .someday)
    }

    /// ⚠️ The reason this is two thresholds rather than three ranges. Stated as ranges ("$1–10",
    /// "$30–60") a $20 card belongs to none of them and the app has to guess silently.
    func testNothingFallsBetweenTheTiers() {
        for price in stride(from: 0.5, through: 200, by: 0.5) {
            XCTAssertNotNil(tiers.tier(for: price), "\(price) fell through")
        }
        XCTAssertEqual(tiers.tier(for: 20), .occasional, "the old gap between $10 and $30")
    }

    /// An unpriced card is routine, not a daydream: we do not know what it costs, and exiling it
    /// to Someday would be a claim we cannot support.
    func testAnUnpricedCardIsRoutineNotSomeday() {
        XCTAssertEqual(tiers.tier(for: nil), .routine)
    }

    func testTheBuyingCeilingIsTheOccasionalLine() {
        XCTAssertEqual(tiers.buyingCeiling, 60)
    }

    /// A hand-edited or restored value must not be able to invert the two lines.
    func testNormalizedKeepsTheLinesInOrder() {
        let inverted = PriceTiers(routineCeiling: 100, occasionalCeiling: 5).normalized
        XCTAssertLessThan(inverted.routineCeiling, inverted.occasionalCeiling)
        let zeroed = PriceTiers(routineCeiling: 0, occasionalCeiling: 0).normalized
        XCTAssertGreaterThan(zeroed.routineCeiling, 0)
        XCTAssertGreaterThan(zeroed.occasionalCeiling, zeroed.routineCeiling)
    }

    func testDefaultsAreTheOnesThePickerPreselects() {
        XCTAssertTrue(PriceTiers.choicesRoutine.contains(PriceTiers.default.routineCeiling))
        XCTAssertTrue(PriceTiers.choicesOccasional.contains(PriceTiers.default.occasionalCeiling))
        XCTAssertLessThan(PriceTiers.default.routineCeiling, PriceTiers.default.occasionalCeiling)
    }

    // MARK: precedence — purchases → targets → stated tiers → nil

    func testTheStatedTiersCarryTheBandWhenThereIsNoHistory() throws {
        let band = try XCTUnwrap(PriceBand.make(entries: [], wants: [:], seed: tiers, now: now))
        XCTAssertEqual(band.p75, 60, "the band spans the whole buying range")
        XCTAssertEqual(band.p50, 10)
    }

    /// The seed evaporates on its own: three real purchases win the first branch and it is never
    /// consulted again. Nothing to migrate, nothing to expire.
    func testThreePurchasesOverrideTheStatedTiers() throws {
        let entries = [entry("a", paid: 5), entry("b", paid: 6), entry("c", paid: 7)]
        let band = try XCTUnwrap(PriceBand.make(entries: entries, wants: [:],
                                                seed: PriceTiers(routineCeiling: 50,
                                                                 occasionalCeiling: 500),
                                                now: now))
        XCTAssertLessThan(band.p75, 50, "purchase history must beat a stated guess")
    }

    func testTooFewPurchasesFallThroughToTheStatedTiers() throws {
        let entries = [entry("a", paid: 5), entry("b", paid: 6)]
        let band = try XCTUnwrap(PriceBand.make(entries: entries, wants: [:], seed: tiers, now: now))
        XCTAssertEqual(band.p75, 60)
    }

    func testTargetsBeatTheStatedTiers() throws {
        let wants = ["a": WantEntry(targetUsd: 90, addedAt: now),
                     "b": WantEntry(targetUsd: 200, addedAt: now),
                     "c": WantEntry(targetUsd: 250, addedAt: now)]
        let band = try XCTUnwrap(PriceBand.make(entries: [], wants: wants, seed: tiers, now: now))
        XCTAssertGreaterThan(band.p75, 60, "a number the user typed outranks a range they tapped")
    }

    func testNoHistoryAndNoStatedTiersIsStillNil() {
        XCTAssertNil(PriceBand.make(entries: [], wants: [:], seed: nil, now: now))
    }
}
