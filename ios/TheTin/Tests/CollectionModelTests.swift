import XCTest
@testable import TheTin

@MainActor
final class CollectionModelTests: XCTestCase {
    private var store: CatalogStore!
    private var repo: InMemoryCollectionRepository!
    private var model: CollectionModel!

    override func setUp() async throws {
        store = try CatalogStore(path: try FixtureCatalog.copyToTemp())
        repo = InMemoryCollectionRepository()
        model = CollectionModel(repository: repo, store: store)
        await model.start()
    }

    override func tearDownWithError() throws { try store?.close() }

    private func waitForStreams() async {
        // Streams hop through continuations; yield a few times to let them land.
        for _ in 0..<10 { await Task.yield() }
    }

    func testCreateGroupAndAddEntryComputesValue() async throws {
        await model.createGroup(name: "Chase")
        await waitForStreams()
        let group = try XCTUnwrap(model.groups.first)

        await model.saveEntry(CollectionEntry(
            id: UUID().uuidString, cardId: "swsh7-215", groupId: group.id, qty: 2,
            condition: "NM", grade: "psa10", pricePaid: 800, acquiredAt: nil,
            acquiredFrom: "card show", addedAt: Date()))
        await model.saveEntry(CollectionEntry(
            id: UUID().uuidString, cardId: "swsh7-12", groupId: group.id, qty: 1,
            condition: "LP", grade: nil, pricePaid: nil, acquiredAt: nil,
            acquiredFrom: nil, addedAt: Date()))
        await waitForStreams()

        XCTAssertEqual(model.entries(in: group.id).count, 2)
        let value = model.groupValue(group.id)
        XCTAssertEqual(value.total, 1010)        // 2 × psa10 505; Metapod unpriced
        XCTAssertEqual(value.pricedCards, 2)     // physical cards (qty 2), not entry rows
        XCTAssertEqual(value.totalCards, 3)
    }

    func testSortByValue() async throws {
        await model.createGroup(name: "Binder")
        await waitForStreams()
        let gid = try XCTUnwrap(model.groups.first).id
        for (card, qty) in [("sv1-25", 1), ("swsh7-215", 1)] {
            await model.saveEntry(CollectionEntry(
                id: card, cardId: card, groupId: gid, qty: qty, condition: nil, grade: nil,
                pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date()))
        }
        await waitForStreams()
        XCTAssertEqual(model.sortedEntries(in: gid, byValue: true).map(\.cardId),
                       ["swsh7-215", "sv1-25"])
    }

    func testRenameGroupUpdatesName() async throws {
        await model.createGroup(name: "Original")
        await waitForStreams()
        let group = try XCTUnwrap(model.groups.first)

        await model.renameGroup(id: group.id, name: "Renamed")
        await waitForStreams()

        let renamed = try XCTUnwrap(model.groups.first(where: { $0.id == group.id }))
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertEqual(model.groups.count, 1)
    }

    func testDeleteGroupCascades() async throws {
        await model.createGroup(name: "Temp")
        await waitForStreams()
        let gid = try XCTUnwrap(model.groups.first).id
        await model.saveEntry(CollectionEntry(
            id: "e1", cardId: "sv1-1", groupId: gid, qty: 1, condition: nil, grade: nil,
            pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date()))
        await waitForStreams()
        await model.deleteGroup(id: gid)
        await waitForStreams()
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testCommitScanToGroupCreatesOwnedEntryWithVariant() async throws {
        let repo = InMemoryCollectionRepository()
        let model = CollectionModel(repository: repo, store: try FixtureCatalog.make())
        let gid = try await repo.createGroup(name: "Binder")
        let draft = ScanDraft(id: "d1", cardId: "ex6-58", variant: .reverseHolo, condition: .lp,
                              qty: 1, addedAt: Date(), priceUsdSnapshot: 4.0)
        let ok = await model.commitScan(draft, to: .group(gid))
        XCTAssertTrue(ok)
        let entry = repo.entries.first
        XCTAssertEqual(entry?.groupId, gid)
        XCTAssertEqual(entry?.variant, "reverseHolo")
        XCTAssertEqual(entry?.condition, "LP")
        XCTAssertEqual(entry?.cardId, "ex6-58")
    }

    func testCommitScanToTinUsesEmptyGroupId() async throws {
        let repo = InMemoryCollectionRepository()
        let model = CollectionModel(repository: repo, store: try FixtureCatalog.make())
        let draft = ScanDraft(id: "d2", cardId: "ex8-63", variant: .regular, condition: .nm,
                              qty: 1, addedAt: Date(), priceUsdSnapshot: nil)
        let ok = await model.commitScan(draft, to: .tin)
        XCTAssertTrue(ok)
        XCTAssertEqual(repo.entries.first?.groupId, "")
    }

    func testCommitScanToNewGroupCreatesGroup() async throws {
        let repo = InMemoryCollectionRepository()
        let model = CollectionModel(repository: repo, store: try FixtureCatalog.make())
        let ok = await model.commitScan(
            ScanDraft(id: "d3", cardId: "ex6-58", variant: .holo, condition: .nm,
                      qty: 1, addedAt: Date(), priceUsdSnapshot: nil),
            to: .newGroup("Trade binder"))
        XCTAssertTrue(ok)
        XCTAssertEqual(repo.groups.map(\.name), ["Trade binder"])
        XCTAssertEqual(repo.entries.first?.groupId, repo.groups.first?.id)
    }

    func testUngroupedEntriesSurfaceInTinButNotAnyGroup() async throws {
        let repo = InMemoryCollectionRepository()
        let model = CollectionModel(repository: repo, store: try FixtureCatalog.make())
        _ = await model.commitScan(
            ScanDraft(id: "t1", cardId: "ex6-58", variant: .regular, condition: .nm,
                      qty: 1, addedAt: Date(), priceUsdSnapshot: nil), to: .tin)
        await model.start()
        await waitForStreams()
        XCTAssertEqual(model.ungroupedEntries.map(\.cardId), ["ex6-58"])
        XCTAssertTrue(model.entries(in: "some-group").isEmpty)
        XCTAssertEqual(model.allOwnedEntries.count, model.entries.count)
    }

    func testEntriesChangePublishesWidgetSnapshot() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.widgetWriter = WidgetSnapshotWriter(containerURL: dir, debounce: .milliseconds(10),
                                                  reload: {})

        await model.saveEntry(CollectionEntry(
            id: UUID().uuidString, cardId: "swsh7-215", groupId: "", qty: 2,
            condition: "NM", grade: "psa10", pricePaid: nil, acquiredAt: nil,
            acquiredFrom: nil, addedAt: Date()))
        await waitForStreams()
        try await Task.sleep(for: .milliseconds(300))

        let data = try Data(contentsOf: WidgetShared.snapshotURL(container: dir))
        let snap = try WidgetShared.decoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(snap.totalValue, 1010)      // 2 × psa10 $505 (same math as the header)
        XCTAssertEqual(snap.cardCount, 2)          // Σ qty, not entry count
        XCTAssertNotNil(snap.asOf)                 // fixture prices carry an as_of date
        // delta7d/sparkline plumbing (incl. the history-present case) is covered by
        // testWidgetSnapshotCarriesPortfolioFieldsWhenHistoryExists below.
    }

    func testWidgetSnapshotCarriesPortfolioFieldsWhenHistoryExists() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.widgetWriter = WidgetSnapshotWriter(containerURL: dir, debounce: .milliseconds(10),
                                                  reload: {})
        await model.saveEntry(CollectionEntry(
            id: UUID().uuidString, cardId: "swsh7-215", groupId: "", qty: 1,
            condition: "NM", grade: nil, pricePaid: nil, acquiredAt: nil,
            acquiredFrom: nil, addedAt: Date()))
        await waitForStreams()
        try await Task.sleep(for: .milliseconds(300))

        let data = try Data(contentsOf: WidgetShared.snapshotURL(container: dir))
        let snap = try WidgetShared.decoder().decode(WidgetSnapshot.self, from: data)
        // Sparkline mirrors the portfolio series: present iff the fixture card has ≥2 history
        // points; never present with fewer. Either way the snapshot itself must be valid.
        let history = (try? store.priceHistory(cardId: "swsh7-215")) ?? []
        if history.count >= 2 {
            XCTAssertNotNil(snap.sparkline)
            XCTAssertLessThanOrEqual(snap.sparkline!.count, 12)
        } else {
            XCTAssertNil(snap.sparkline)
        }
        XCTAssertEqual(snap.totalValue, 92.5)   // raw price, unchanged by history wiring
    }

    func testWidgetSnapshotPopulatesDelta7dForOldEntry() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.widgetWriter = WidgetSnapshotWriter(containerURL: dir, debounce: .milliseconds(10),
                                                  reload: {})
        // Fixture price_history for swsh7-215 spans 2026-01-05→2026-01-19; an acquiredAt 60 days
        // back makes PortfolioHistory.series bucket weekly from then to now, well past the
        // 7-day delta cutoff, so the populated path (unlike the other tests here) is exercised.
        await model.saveEntry(CollectionEntry(
            id: UUID().uuidString, cardId: "swsh7-215", groupId: "", qty: 1,
            condition: "NM", grade: nil, pricePaid: nil,
            acquiredAt: Date(timeIntervalSinceNow: -60 * 24 * 3600), acquiredFrom: nil,
            addedAt: Date()))
        await waitForStreams()
        try await Task.sleep(for: .milliseconds(300))

        let data = try Data(contentsOf: WidgetShared.snapshotURL(container: dir))
        let snap = try WidgetShared.decoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertNotNil(snap.delta7d)
        // History's last point (2026-01-19, raw_usd 92.5) matches price_latest's raw_usd 92.5,
        // so every weekly bucket after Jan 19 clamps to the same flat value — 7-day movement is
        // deterministically zero for this fixture.
        XCTAssertEqual(snap.delta7d!, 0, accuracy: 0.0001)
    }

    func testWidgetSnapshotHidesSparklineWhenNoCardHasHistory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.widgetWriter = WidgetSnapshotWriter(containerURL: dir, debounce: .milliseconds(10),
                                                  reload: {})
        // sv1-25 has a price_latest row but NO price_history rows (unlike swsh7-215). An old
        // acquiredAt still yields ≥2 weekly-bucketed points — PortfolioHistory.series buckets
        // from ownedDates regardless of history coverage, so every point's value is 0. The
        // sparkline/delta must stay nil rather than publish a bogus flat line (doc comment:
        // "empty history ⇒ value-only snapshot").
        await model.saveEntry(CollectionEntry(
            id: UUID().uuidString, cardId: "sv1-25", groupId: "", qty: 1,
            condition: "NM", grade: nil, pricePaid: nil,
            acquiredAt: Date(timeIntervalSinceNow: -60 * 24 * 3600), acquiredFrom: nil,
            addedAt: Date()))
        await waitForStreams()
        try await Task.sleep(for: .milliseconds(300))

        let data = try Data(contentsOf: WidgetShared.snapshotURL(container: dir))
        let snap = try WidgetShared.decoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertNil(snap.sparkline)
        XCTAssertNil(snap.delta7d)
    }
}
