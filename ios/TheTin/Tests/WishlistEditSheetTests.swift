import XCTest
@testable import TheTin

/// The arming rule for the second door into hunting.
///
/// A hunt needs a budget — `WishlistEditSheet.save()` drops a budgetless hunt on the floor
/// because the eBay query has no ceiling without one. So arming the sheet has to seed a budget
/// from somewhere, and market price is the only number available at the tap site.
final class WishlistEditSheetTests: XCTestCase {
    func testArmingSeedsTheBudgetFromMarketPrice() {
        XCTAssertEqual(WishlistEditSheet.seedBudget(marketUsd: 24.5), "24.50")
    }

    /// An unpriced card seeds nothing rather than "0.00" — `parseBudget` rejects non-positive
    /// values, so a zero seed would arm a hunt that silently refuses to save.
    func testAnUnpricedCardSeedsNothing() {
        XCTAssertEqual(WishlistEditSheet.seedBudget(marketUsd: nil), "")
        XCTAssertEqual(WishlistEditSheet.seedBudget(marketUsd: 0), "")
    }

    /// The seed must survive the sheet's own parser, or arming produces a hunt that cannot save.
    func testTheSeedParsesBackToAPositiveBudget() throws {
        let seed = WishlistEditSheet.seedBudget(marketUsd: 24.5)
        let parsed = try XCTUnwrap(WishlistEditSheet.parseBudget(seed, separator: "."))
        XCTAssertEqual(parsed, 24.5, accuracy: 0.001)
    }
}
