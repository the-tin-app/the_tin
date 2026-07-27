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

    // MARK: target crossings

    func testCrossingFiresOnlyOnTheEdge() {
        let targets = ["crossed": 100.0, "stillAbove": 100.0, "alreadyBelow": 100.0]
        let old = ["crossed": 120.0, "stillAbove": 120.0, "alreadyBelow": 90.0]
        let new = ["crossed": 95.0, "stillAbove": 110.0, "alreadyBelow": 85.0]
        let hits = PriceAlertsService.targetCrossings(old: old, new: new, targets: targets)
        // `alreadyBelow` was under target last night too — announcing it again every night is
        // how an alert becomes something you swipe away without reading.
        XCTAssertEqual(hits.map(\.cardId), ["crossed"])
        XCTAssertEqual(hits.first?.newUsd, 95.0)
        XCTAssertEqual(hits.first?.target, 100.0)
    }

    func testLandingExactlyOnTheTargetCounts() {
        let hits = PriceAlertsService.targetCrossings(
            old: ["a": 120.0], new: ["a": 100.0], targets: ["a": 100.0])
        XCTAssertEqual(hits.map(\.cardId), ["a"], "\"I'll pay $100\" includes $100")
    }

    func testCardWithNoTargetOrNoBaselineNeverCrosses() {
        // No target: the user never named a price, so there is no promise to keep.
        XCTAssertTrue(PriceAlertsService.targetCrossings(
            old: ["a": 120.0], new: ["a": 10.0], targets: [:]).isEmpty)
        // No baseline: hearted since the last snapshot. It may have been cheap for a year —
        // calling that news would be a lie.
        XCTAssertTrue(PriceAlertsService.targetCrossings(
            old: [:], new: ["a": 10.0], targets: ["a": 100.0]).isEmpty)
    }

    func testSubDollarTargetsAreNoise() {
        XCTAssertTrue(PriceAlertsService.targetCrossings(
            old: ["a": 1.0], new: ["a": 0.4], targets: ["a": 0.5]).isEmpty)
    }

    /// The guard that makes this feature safe to ship on `raw_usd`: if the price is quoting a
    /// different printing than it was last night, the two numbers aren't comparable and any
    /// "crossing" between them is arithmetic on a basis flip.
    func testChangedPrintingBasisSuppressesTheCrossing() {
        let args = (old: ["a": 600.0], new: ["a": 80.0], targets: ["a": 550.0])
        XCTAssertEqual(PriceAlertsService.targetCrossings(
            old: args.old, new: args.new, targets: args.targets).map(\.cardId), ["a"])
        XCTAssertTrue(PriceAlertsService.targetCrossings(
            old: args.old, new: args.new, targets: args.targets,
            changedBasis: ["a"]).isEmpty,
            "a 1st Edition price replaced by an Unlimited one is not a card getting cheaper")
    }

    func testCrossingsLeadWithTheBestDeal() {
        let hits = PriceAlertsService.targetCrossings(
            old: ["ok": 100.0, "steal": 100.0],
            new: ["ok": 99.0, "steal": 50.0],
            targets: ["ok": 99.5, "steal": 99.5])
        XCTAssertEqual(hits.map(\.cardId), ["steal", "ok"])
    }

    func testTargetAlertCopyNamesTheTargetAndDigestsPastThree() {
        let names = ["a": "Blastoise", "b": "Umbreon", "c": "Lugia", "d": "Ho-Oh"]
        let one = PriceAlertsService.targetAlerts(
            for: [.init(cardId: "a", target: 550, newUsd: 540)], names: names)
        XCTAssertEqual(one.first?.title, "Blastoise hit your target — $540")
        XCTAssertEqual(one.first?.body, "You were watching for $550.")

        let many = PriceAlertsService.targetAlerts(
            for: ["a", "b", "c", "d"].map { .init(cardId: $0, target: 100, newUsd: 90) },
            names: names)
        XCTAssertEqual(many.count, 1)
        XCTAssertEqual(many.first?.title, "4 wishlist cards hit your target")
    }

    /// A snapshot written before `printings` existed must still decode — otherwise the first
    /// run after updating throws away the baseline and nobody gets an alert that night. (This
    /// caught exactly that: a defaulted non-optional property does NOT make the key optional
    /// for a synthesized `Decodable`.)
    func testSnapshotWithoutPrintingsStillDecodes() throws {
        let json = #"{"catalogVersion":3,"asOf":"2026-07-25","prices":{"a":10}}"#
        let snapshot = try JSONDecoder().decode(PriceAlertsService.Snapshot.self,
                                                from: Data(json.utf8))
        XCTAssertEqual(snapshot.prices["a"], 10)
        XCTAssertNil(snapshot.printings, "nil means 'predates the basis column', not 'no basis'")
    }

    // MARK: runAfterInstall (regression: new {id: WantEntry} wants.json format)

    func testRunAfterInstallReadsNewFormatWantsJSON() async throws {
        // wants.json in the CURRENT {cardId: WantEntry} object format (not the legacy bare id
        // array) — proves runAfterInstall goes through LocalWantsRepository's shared,
        // format-aware loader instead of a Set<String>-only decode that silently sees no ids.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wantsURL = dir.appendingPathComponent("wants.json")
        try JSONEncoder().encode([FixtureCatalog.knownCardId: WantEntry()]).write(to: wantsURL)

        let snapshotURL = dir.appendingPathComponent("snapshot.json")
        let service = PriceAlertsService(snapshotURL: snapshotURL, wantsURL: wantsURL)
        await service.runAfterInstall(version: 1, dbPath: try FixtureCatalog.copyToTemp())

        let snapshot = try JSONDecoder().decode(PriceAlertsService.Snapshot.self,
                                                 from: Data(contentsOf: snapshotURL))
        XCTAssertEqual(snapshot.prices[FixtureCatalog.knownCardId], 0.4,
                       "wished card's price must be captured, proving its id was read from the new format")
    }
}
