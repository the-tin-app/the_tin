import XCTest
@testable import TheTin

final class PriceAlertsServiceTests: XCTestCase {

    // MARK: movers (pure diff)

    func testThresholdBoundaryAlertsAtExactlyThresholdNotBelow() {
        let old = ["at": 100.0, "below": 100.0, "down": 100.0]
        let new = ["at": 110.0, "below": 109.99, "down": 90.0]
        let movers = PriceAlertsService.movers(old: old, new: new, threshold: 0.10)
        XCTAssertEqual(Set(movers.map(\.cardId)), ["at", "down"],
                       "≥ threshold alerts (both directions); just under does not")
    }

    func testDollarFloorSkipsPennyCards() {
        let old = ["penny": 0.50, "dollar": 1.00]
        let new = ["penny": 1.00, "dollar": 2.00]   // both +100%
        let movers = PriceAlertsService.movers(old: old, new: new, threshold: 0.10)
        XCTAssertEqual(movers.map(\.cardId), ["dollar"],
                       "old price under $1 never alerts, $1 exactly does")
    }

    func testNoBaselineCardIsSkipped() {
        // Hearted since the last snapshot: present in new prices, absent from the old snapshot.
        let movers = PriceAlertsService.movers(old: [:], new: ["new-heart": 500.0], threshold: 0.05)
        XCTAssertTrue(movers.isEmpty, "no baseline ⇒ skipped this cycle")
    }

    func testCardRemovedFromCatalogIsDroppedSilently() {
        let movers = PriceAlertsService.movers(old: ["gone": 100.0], new: [:], threshold: 0.05)
        XCTAssertTrue(movers.isEmpty)
    }

    // MARK: alerts (batching + copy)

    func testUpToThreeMoversGetIndividualNotifications() {
        let movers = [
            PriceAlertsService.Mover(cardId: "a", oldUsd: 256.0, newUsd: 210.0),  // ↓18%
            PriceAlertsService.Mover(cardId: "b", oldUsd: 100.0, newUsd: 112.0),  // ↑12%
            PriceAlertsService.Mover(cardId: "c", oldUsd: 10.0, newUsd: 11.0),    // ↑10%
        ]
        let alerts = PriceAlertsService.alerts(for: movers, names: ["a": "Charizard ex"])
        XCTAssertEqual(alerts.count, 3, "1–3 movers ⇒ one notification each")
        XCTAssertEqual(alerts[0].title, "Charizard ex dropped 18% → $210")
        XCTAssertEqual(alerts[0].body, "Was $256")
        XCTAssertEqual(alerts[1].title, "b rose 12% → $112", "missing name falls back to card id")
    }

    func testFourMoversCutOverToSingleDigest() {
        let movers = [
            PriceAlertsService.Mover(cardId: "a", oldUsd: 100.0, newUsd: 120.0),
            PriceAlertsService.Mover(cardId: "b", oldUsd: 100.0, newUsd: 115.0),
            PriceAlertsService.Mover(cardId: "c", oldUsd: 100.0, newUsd: 90.0),
            PriceAlertsService.Mover(cardId: "d", oldUsd: 100.0, newUsd: 106.0),
        ]
        let alerts = PriceAlertsService.alerts(for: movers, names: [:])
        XCTAssertEqual(alerts.count, 1, ">3 movers ⇒ one digest")
        XCTAssertEqual(alerts[0].title, "4 wishlist cards moved")
    }

    func testDigestTruncatesToTopThreeMovers() {
        let names = ["a": "Charizard ex", "b": "Umbreon VMAX", "c": "Pikachu",
                     "d": "Snorlax", "e": "Gengar"]
        let movers = [   // pre-sorted by |pct| descending, as movers() guarantees
            PriceAlertsService.Mover(cardId: "a", oldUsd: 100.0, newUsd: 82.0),   // ↓18%
            PriceAlertsService.Mover(cardId: "b", oldUsd: 100.0, newUsd: 112.0),  // ↑12%
            PriceAlertsService.Mover(cardId: "c", oldUsd: 100.0, newUsd: 110.0),  // ↑10%
            PriceAlertsService.Mover(cardId: "d", oldUsd: 100.0, newUsd: 108.0),
            PriceAlertsService.Mover(cardId: "e", oldUsd: 100.0, newUsd: 107.0),
        ]
        let alerts = PriceAlertsService.alerts(for: movers, names: names)
        XCTAssertEqual(alerts, [PriceAlertsService.Alert(
            title: "5 wishlist cards moved",
            body: "Charizard ex ↓18%, Umbreon VMAX ↑12%, Pikachu ↑10%, …")])
        XCTAssertFalse(alerts[0].body.contains("Snorlax"), "digest names only the top 3")
    }
}
