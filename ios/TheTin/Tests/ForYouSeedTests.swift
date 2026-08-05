import XCTest
@testable import TheTin

/// The first-run seed: what a collector says they spend, before there is any purchase history to
/// infer it from.
final class ForYouSeedTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func entry(_ id: String, paid: Double?) -> CollectionEntry {
        CollectionEntry(id: UUID().uuidString, cardId: id, groupId: "", qty: 1,
                        condition: nil, grade: nil, pricePaid: paid, acquiredAt: now,
                        acquiredFrom: nil, addedAt: now)
    }

    // MARK: budget → band

    func testEachBudgetMapsToAUsableBand() throws {
        XCTAssertEqual(DiscoverBudget.under10.band, PriceBand(p25: 2, p50: 5, p75: 10))
        XCTAssertEqual(DiscoverBudget.tenToFifty.band, PriceBand(p25: 10, p50: 25, p75: 50))
        XCTAssertEqual(DiscoverBudget.fiftyToTwoHundred.band, PriceBand(p25: 50, p50: 100, p75: 200))
    }

    /// ⚠️ `.more` yields NO band on purpose. There is no honest range to infer above $200 from one
    /// tap, and no band is better than a wrong one: a band that matches everything is precisely what
    /// made the first build of this feature measure as inert.
    func testMoreAndSkippedYieldNoBand() {
        XCTAssertNil(DiscoverBudget.more.band)
        XCTAssertNil(DiscoverBudget.skipped.band)
    }

    func testEveryBandIsOrderedAndPositive() throws {
        for option in DiscoverBudget.allCases {
            guard let band = option.band else { continue }
            XCTAssertLessThan(band.p25, band.p50, option.rawValue)
            XCTAssertLessThan(band.p50, band.p75, option.rawValue)
            XCTAssertGreaterThan(band.p25, 0, option.rawValue)
        }
    }

    func testEveryOptionHasALabel() {
        for option in DiscoverBudget.allCases {
            XCTAssertFalse(option.label.isEmpty, option.rawValue)
        }
    }

    // MARK: precedence — purchases → targets → seed → nil

    func testTheSeedCarriesTheBandWhenThereIsNoHistory() {
        XCTAssertEqual(PriceBand.make(entries: [], wants: [:], seed: .tenToFifty, now: now),
                       PriceBand(p25: 10, p50: 25, p75: 50))
    }

    /// The seed evaporates on its own: once three real purchases exist the first branch wins and it
    /// is never consulted again. Nothing to migrate, nothing to expire.
    func testThreePurchasesOverrideTheSeed() throws {
        let entries = [entry("a", paid: 5), entry("b", paid: 6), entry("c", paid: 7)]
        let band = try XCTUnwrap(PriceBand.make(entries: entries, wants: [:],
                                                seed: .fiftyToTwoHundred, now: now))
        XCTAssertLessThan(band.p75, 50, "purchase history must beat a seeded guess")
    }

    /// Two purchases are below `minimumSamples`, so the seed still carries.
    func testTooFewPurchasesFallThroughToTheSeed() {
        let entries = [entry("a", paid: 5), entry("b", paid: 6)]
        XCTAssertEqual(PriceBand.make(entries: entries, wants: [:], seed: .under10, now: now),
                       PriceBand(p25: 2, p50: 5, p75: 10))
    }

    /// Wishlist targets sit between purchases and the seed — an aspirational number the user typed
    /// still beats a range they tapped once.
    func testTargetsBeatTheSeed() throws {
        let wants = ["a": WantEntry(targetUsd: 90, addedAt: now),
                     "b": WantEntry(targetUsd: 200, addedAt: now),
                     "c": WantEntry(targetUsd: 250, addedAt: now)]
        let band = try XCTUnwrap(PriceBand.make(entries: [], wants: wants, seed: .under10, now: now))
        XCTAssertGreaterThan(band.p75, 10, "targets outrank the seeded range")
    }

    func testNoHistoryAndNoSeedIsStillNil() {
        XCTAssertNil(PriceBand.make(entries: [], wants: [:], seed: nil, now: now))
    }

    func testSkippingThePickerLeavesNoBandRatherThanAGuess() {
        XCTAssertNil(PriceBand.make(entries: [], wants: [:], seed: .skipped, now: now))
    }
}
