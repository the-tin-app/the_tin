import XCTest
@testable import TheTin

@MainActor
final class CollectionModelTests: XCTestCase {
    private var store: CatalogStore!
    private var repo: InMemoryCollectionRepository!
    private var model: CollectionModel!

    override func setUp() async throws {
        // `entries.didSet` writes this, and `CollectionModel` reads it at init — so it outlives the
        // process and would leak between runs if it weren't pinned at both ends.
        UserDefaults.standard.set(false, forKey: "hasCards")
        store = try CatalogStore(path: try FixtureCatalog.copyToTemp())
        repo = InMemoryCollectionRepository()
        model = CollectionModel(repository: repo, store: store)
        await model.start()
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "hasCards")
        try store?.close()
    }

    private func waitForStreams() async {
        // Streams hop through continuations; yield a few times to let them land.
        for _ in 0..<10 { await Task.yield() }
    }

    /// `entries` is empty for the frames before the stream delivers, so `entries.isEmpty` alone
    /// would put a returning user on "Your tin is empty" — the one screen that reads as data loss.
    func testEmptyEntriesBeforeTheFirstEmissionReadAsLoadingNotEmpty() async throws {
        UserDefaults.standard.set(true, forKey: "hasCards")
        let waiting = CollectionModel(repository: InMemoryCollectionRepository(), store: store)

        XCTAssertTrue(waiting.entries.isEmpty)
        XCTAssertTrue(waiting.isAwaitingFirstLoad)

        await waiting.start()
        await waitForStreams()

        // Still empty — but now that's an answer rather than an absence.
        XCTAssertTrue(waiting.entries.isEmpty)
        XCTAssertFalse(waiting.isAwaitingFirstLoad)
    }

    /// The other half: a first run must NOT be held on a placeholder waiting for a tin it never had.
    func testFirstRunFallsStraightThroughToTheEmptyTin() async throws {
        UserDefaults.standard.set(false, forKey: "hasCards")
        let fresh = CollectionModel(repository: InMemoryCollectionRepository(), store: store)

        XCTAssertFalse(fresh.isAwaitingFirstLoad)
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
        // Value sort lives in GroupStats (the view's sort menu calls it directly).
        XCTAssertEqual(GroupStats.sortedByValueDescending(
                           entries: model.entries(in: gid), prices: model.prices,
                           variantsByCard: model.variantsByCard,
                           conditionsByCard: model.conditionsByCard).map(\.cardId),
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
                              qty: 1, addedAt: Date(), priceUsdSnapshot: 4.0, acquiredVia: .pulled)
        let ok = await model.commitScan(draft, to: .group(gid))
        XCTAssertTrue(ok)
        let entry = repo.entries.first
        XCTAssertEqual(entry?.groupId, gid)
        XCTAssertEqual(entry?.variant, "reverseHolo")
        XCTAssertEqual(entry?.condition, "LP")
        XCTAssertEqual(entry?.cardId, "ex6-58")
        XCTAssertEqual(entry?.acquiredVia, "pulled")
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

    /// The cached per-divider totals must equal what a direct `GroupStats.totalValue` over that
    /// divider's entries returns — the whole point of bucketing in one pass is that nobody can
    /// tell it happened. Ungrouped entries ("" groupId) are their own bucket and must not leak
    /// into a named divider's total.
    func testCachedGroupTotalsMatchDirectComputation() async throws {
        await model.createGroup(name: "Binder A")
        await model.createGroup(name: "Binder B")
        await waitForStreams()
        let a = try XCTUnwrap(model.groups.first).id
        let b = try XCTUnwrap(model.groups.last).id
        XCTAssertNotEqual(a, b)

        for (card, group) in [("swsh7-215", a), ("sv1-25", a), ("swsh7-12", b), ("ex6-58", "")] {
            await model.saveEntry(CollectionEntry(
                id: UUID().uuidString, cardId: card, groupId: group, qty: 1, condition: "NM",
                grade: nil, pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date()))
        }
        await waitForStreams()

        for group in [a, b, ""] {
            let direct = GroupStats.totalValue(
                entries: model.entries(in: group), prices: model.prices,
                variantsByCard: model.variantsByCard, conditionsByCard: model.conditionsByCard,
                matrixByCard: model.matrixByCard,
                gradedByPrintingByCard: model.gradedByPrintingByCard)
            let cached = model.groupValue(group)
            XCTAssertEqual(cached.total, direct.total, accuracy: 0.001, "group \(group)")
            XCTAssertEqual(cached.pricedCards, direct.pricedCards, "group \(group)")
            XCTAssertEqual(cached.totalCards, direct.totalCards, "group \(group)")
        }

        // The whole tin is every bucket, so its card count is the sum of theirs.
        XCTAssertEqual(model.tinValue.totalCards, 4)
        XCTAssertEqual(model.tinValue.total,
                       [a, b, ""].reduce(0) { $0 + model.groupValue($1).total }, accuracy: 0.001)
        // A divider that has never held a card has no bucket at all.
        XCTAssertEqual(model.groupValue("never-existed").totalCards, 0)
    }

    /// `entryValue` returns the value of the WHOLE row (unit × qty), not one copy.
    ///
    /// The card screen's "paid → now" line leans on this: it compares `entryValue` against
    /// `pricePaid`, which is spec-locked as the row total. If this ever became a per-copy figure,
    /// a ×4 row would silently compare one copy's value against four copies' cost and report a
    /// 75% loss on a card that hadn't moved.
    func testEntryValueIsTheRowTotalNotOneCopy() async throws {
        let one = CollectionEntry(
            id: "one", cardId: "swsh7-215", groupId: "", qty: 1, condition: "NM", grade: "psa10",
            pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date())
        await model.saveEntry(one)
        await waitForStreams()
        let unit = try XCTUnwrap(model.entryValue(try XCTUnwrap(model.entries.first)))

        // A separate row for the same card, three copies — differing qty alone keeps it its own
        // row only if something blocks the merge, so use a distinct divider.
        await model.saveEntry(CollectionEntry(
            id: "three", cardId: "swsh7-215", groupId: "elsewhere", qty: 3, condition: "NM",
            grade: "psa10", pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date()))
        await waitForStreams()
        let triple = try XCTUnwrap(model.entries.first { $0.id == "three" })
        XCTAssertEqual(try XCTUnwrap(model.entryValue(triple)), unit * 3, accuracy: 0.001)
    }

    // MARK: sold / traded away

    /// A sold copy leaves everything that measures what you own, and keeps everything that
    /// records what happened.
    func testSoldEntryLeavesTheTotalsButKeepsItsHistory() async throws {
        await model.saveEntry(CollectionEntry(
            id: "keep", cardId: "swsh7-215", groupId: "", qty: 1, condition: "NM", grade: "psa10",
            pricePaid: 400, acquiredAt: nil, acquiredFrom: "a card show", addedAt: Date()))
        await model.saveEntry(CollectionEntry(
            id: "gone", cardId: "sv1-25", groupId: "", qty: 1, condition: "NM", grade: nil,
            pricePaid: 30, acquiredAt: nil, acquiredFrom: nil, addedAt: Date()))
        await waitForStreams()
        let before = model.tinValue
        XCTAssertEqual(before.totalCards, 2)

        let gone = try XCTUnwrap(model.entries.first { $0.id == "gone" })
        await model.markSold(gone, on: Date(), for: 25)
        await waitForStreams()

        XCTAssertEqual(model.entries.map(\.id), ["keep"], "sold copies leave `entries`")
        XCTAssertEqual(model.soldEntries.map(\.id), ["gone"])
        XCTAssertEqual(model.allEntries.count, 2, "and stay on file")
        XCTAssertEqual(model.tinValue.totalCards, 1, "and stop counting toward what you own")
        XCTAssertEqual(model.entries(in: "").map(\.id), ["keep"])

        let sold = try XCTUnwrap(model.soldEntries.first)
        XCTAssertEqual(sold.soldFor, 25)
        XCTAssertEqual(sold.pricePaid, 30, "cost basis survives the sale — that's the whole point")
    }

    /// The trap this feature is most likely to spring: `undoLastDelete` hands `replaceAll` a
    /// complete collection. Built from the owned-only list it would rewrite the file without a
    /// single sold row — one tap on Undo silently erasing every sale you'd ever recorded.
    func testUndoAfterASaleDoesNotWipeTheSoldRows() async throws {
        await model.saveEntry(CollectionEntry(
            id: "sold", cardId: "swsh7-215", groupId: "", qty: 1, condition: "NM", grade: nil,
            pricePaid: 100, acquiredAt: nil, acquiredFrom: nil, addedAt: Date()))
        await model.saveEntry(CollectionEntry(
            id: "doomed", cardId: "sv1-25", groupId: "", qty: 1, condition: "NM", grade: nil,
            pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date()))
        await waitForStreams()
        await model.markSold(try XCTUnwrap(model.entries.first { $0.id == "sold" }),
                             on: Date(), for: 90)
        await waitForStreams()

        await model.deleteEntry(id: "doomed")
        await waitForStreams()
        await model.undoLastDelete()
        await waitForStreams()

        XCTAssertEqual(model.entries.map(\.id), ["doomed"], "the delete is undone")
        XCTAssertEqual(model.soldEntries.map(\.id), ["sold"], "and the sale survived it")
        XCTAssertEqual(model.soldEntries.first?.soldFor, 90)
    }

    /// Selling is reversible, and editing a sold row updates it rather than minting a twin —
    /// `saveEntry` decides update-vs-add by searching, and the owned-only list wouldn't find it.
    func testSoldCopyCanComeBackAndCanBeEditedInPlace() async throws {
        await model.saveEntry(CollectionEntry(
            id: "e", cardId: "swsh7-215", groupId: "", qty: 1, condition: "NM", grade: nil,
            pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date()))
        await waitForStreams()
        await model.markSold(try XCTUnwrap(model.entries.first), on: Date(), for: 10)
        await waitForStreams()

        var edited = try XCTUnwrap(model.soldEntries.first)
        edited.acquiredFrom = "traded at the meetup"
        await model.saveEntry(edited)
        await waitForStreams()
        XCTAssertEqual(model.allEntries.count, 1, "edited in place, not duplicated")

        await model.markUnsold(try XCTUnwrap(model.soldEntries.first))
        await waitForStreams()
        XCTAssertTrue(model.soldEntries.isEmpty)
        XCTAssertEqual(model.entries.map(\.id), ["e"])
        XCTAssertEqual(model.entries.first?.acquiredFrom, "traded at the meetup")
    }

    /// Re-buying a card you once sold must not resurrect the sold row into a "×2".
    func testBuyingAgainDoesNotFoldIntoASoldCopy() async throws {
        await model.saveEntry(CollectionEntry(
            id: "old", cardId: "swsh7-215", groupId: "", qty: 1, condition: "NM", grade: nil,
            pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date()))
        await waitForStreams()
        await model.markSold(try XCTUnwrap(model.entries.first), on: Date(), for: 500)
        await waitForStreams()

        await model.saveEntry(CollectionEntry(
            id: "new", cardId: "swsh7-215", groupId: "", qty: 1, condition: "NM", grade: nil,
            pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date()))
        await waitForStreams()

        XCTAssertEqual(model.entries.map(\.id), ["new"])
        XCTAssertEqual(model.entries.first?.qty, 1, "the sold copy must not be revived as a ×2")
        XCTAssertEqual(model.soldEntries.first?.soldFor, 500)
    }

    /// The trade list is cached alongside the totals; deleting the last flagged copy has to empty
    /// it, or the tin's "For Trade" row keeps counting a card that isn't there.
    func testCachedTradeListTracksTheForTradeFlag() async throws {
        let entry = CollectionEntry(
            id: "t1", cardId: "swsh7-215", groupId: "", qty: 1, condition: "NM", grade: nil,
            pricePaid: nil, acquiredAt: nil, acquiredFrom: nil, addedAt: Date())
        await model.saveEntry(entry)
        await waitForStreams()
        XCTAssertTrue(model.tradeEntries.isEmpty)

        await model.setForTrade(try XCTUnwrap(model.entries.first), true)
        await waitForStreams()
        XCTAssertEqual(model.tradeEntries.map(\.cardId), ["swsh7-215"])
        XCTAssertEqual(model.tradeValue.totalCards, 1)

        await model.setForTrade(try XCTUnwrap(model.entries.first), false)
        await waitForStreams()
        XCTAssertTrue(model.tradeEntries.isEmpty)
        XCTAssertEqual(model.tradeValue.totalCards, 0)
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

    // MARK: adding a card you already own

    private func plainEntry(_ cardId: String, qty: Int = 1, groupId: String = "",
                            pricePaid: Double? = nil, acquiredFrom: String? = nil) -> CollectionEntry {
        CollectionEntry(id: UUID().uuidString, cardId: cardId, groupId: groupId, qty: qty,
                        condition: "NM", grade: nil, pricePaid: pricePaid, acquiredAt: nil,
                        acquiredFrom: acquiredFrom, addedAt: Date(), variant: "regular")
    }

    func testSavingAnIdenticalPlainCopyBumpsQuantity() async throws {
        await model.saveEntry(plainEntry("swsh7-215"))
        await waitForStreams()
        await model.saveEntry(plainEntry("swsh7-215", qty: 2))
        await waitForStreams()

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.qty, 3)
    }

    func testCopiesThatDifferStayTheirOwnRows() async throws {
        await model.saveEntry(plainEntry("swsh7-215"))
        await waitForStreams()
        // A recorded acquisition is its own cost basis — folding it in would destroy it.
        await model.saveEntry(plainEntry("swsh7-215", pricePaid: 400, acquiredFrom: "card show"))
        // Different sleeve details are different copies.
        var graded = plainEntry("swsh7-215")
        graded.grade = "psa10"
        await model.saveEntry(graded)
        var reverse = plainEntry("swsh7-215")
        reverse.variant = "reverseHolo"
        await model.saveEntry(reverse)
        await model.saveEntry(plainEntry("swsh7-215", groupId: "elsewhere"))
        await waitForStreams()

        XCTAssertEqual(model.entries.count, 5)
        XCTAssertTrue(model.entries.allSatisfy { $0.qty == 1 })
    }

    // MARK: bulk refiling

    func testMoveEntriesRefilesEveryCardInOneWrite() async throws {
        await model.createGroup(name: "Binder")
        await waitForStreams()
        let gid = try XCTUnwrap(model.groups.first).id
        for card in ["swsh7-215", "swsh7-12", "sv1-25"] {
            await model.saveEntry(plainEntry(card, pricePaid: 1))   // distinct rows, no folding
        }
        await waitForStreams()

        await model.moveEntries(ids: Set(model.entries.map(\.id)), toGroup: gid)
        await waitForStreams()

        XCTAssertEqual(model.entries(in: gid).count, 3)
        XCTAssertTrue(model.ungroupedEntries.isEmpty)
    }

    func testMoveEntriesFoldIntoIdenticalCopiesAtTheDestination() async throws {
        await model.createGroup(name: "Binder")
        await waitForStreams()
        let gid = try XCTUnwrap(model.groups.first).id
        // One plain copy already behind the divider, two more arriving from the tin.
        await model.saveEntry(plainEntry("swsh7-215", groupId: gid))
        await model.saveEntry(plainEntry("swsh7-215"))
        await waitForStreams()
        await model.saveEntry(plainEntry("swsh7-215"))   // folds into the ungrouped copy → ×2
        await waitForStreams()

        await model.moveEntries(ids: Set(model.ungroupedEntries.map(\.id)), toGroup: gid)
        await waitForStreams()

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.qty, 3)
        XCTAssertEqual(model.entries.first?.groupId, gid)
    }

    func testMoveEntriesKeepsCopiesThatRecordAnAcquisition() async throws {
        await model.createGroup(name: "Binder")
        await waitForStreams()
        let gid = try XCTUnwrap(model.groups.first).id
        await model.saveEntry(plainEntry("swsh7-215", groupId: gid))
        await model.saveEntry(plainEntry("swsh7-215", pricePaid: 400, acquiredFrom: "card show"))
        await waitForStreams()

        await model.moveEntries(ids: Set(model.ungroupedEntries.map(\.id)), toGroup: gid)
        await waitForStreams()

        XCTAssertEqual(model.entries(in: gid).count, 2)
        XCTAssertEqual(model.entries(in: gid).map(\.qty), [1, 1])
    }

    func testCommitScanFoldsIntoAnIdenticalPlainCopy() async throws {
        await model.saveEntry(plainEntry("ex6-58"))
        await waitForStreams()
        let ok = await model.commitScan(
            ScanDraft(id: "dup", cardId: "ex6-58", variant: .regular, condition: .nm,
                      qty: 1, addedAt: Date(), priceUsdSnapshot: nil), to: .tin)
        await waitForStreams()

        XCTAssertTrue(ok)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.qty, 2)
    }

    // MARK: Undo

    /// A deleted entry comes back as the SAME row — same id, same acquisition detail — so undo
    /// restores what you had rather than something that merely looks like it.
    func testUndoRestoresADeletedEntryWithItsIdAndDetail() async throws {
        await model.saveEntry(plainEntry("swsh7-215", pricePaid: 400, acquiredFrom: "card show"))
        await waitForStreams()
        let original = try XCTUnwrap(model.entries.first)

        await model.deleteEntry(id: original.id)
        await waitForStreams()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNotNil(model.undoable)

        await model.undoLastDelete()
        await waitForStreams()

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first, original)
        XCTAssertNil(model.undoable, "the offer is spent once taken")
    }

    /// Deleting a divider with its cards is the scariest action in the app: undo has to bring back
    /// the divider AND everything filed behind it, still filed behind it.
    func testUndoRestoresADeletedDividerAndItsCards() async throws {
        await model.createGroup(name: "Binder A")
        await waitForStreams()
        let gid = try XCTUnwrap(model.groups.first).id
        await model.saveEntry(plainEntry("swsh7-215", groupId: gid))
        await model.saveEntry(plainEntry("ex6-58", groupId: gid))
        await waitForStreams()

        await model.deleteGroup(id: gid)
        await waitForStreams()
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertTrue(model.entries.isEmpty)

        await model.undoLastDelete()
        await waitForStreams()

        XCTAssertEqual(model.groups.map(\.id), [gid])
        XCTAssertEqual(model.entries(in: gid).count, 2)
    }

    /// "Delete divider, keep its cards" leaves the rows behind with no divider. Undo must re-file
    /// them, not just re-create an empty divider beside them.
    func testUndoRefilesCardsKeptFromADeletedDivider() async throws {
        await model.createGroup(name: "Binder A")
        await waitForStreams()
        let gid = try XCTUnwrap(model.groups.first).id
        await model.saveEntry(plainEntry("swsh7-215", groupId: gid))
        await waitForStreams()

        await model.deleteGroup(id: gid, keepingEntries: true)
        await waitForStreams()
        XCTAssertEqual(model.ungroupedEntries.count, 1, "the card survives, unfiled")

        await model.undoLastDelete()
        await waitForStreams()

        XCTAssertEqual(model.entries(in: gid).count, 1)
        XCTAssertTrue(model.ungroupedEntries.isEmpty)
    }

    /// Only the most recent delete is offered back — the toast shows one thing, so holding more
    /// would promise an undo stack the UI doesn't have.
    func testOnlyTheMostRecentDeleteIsOffered() async throws {
        await model.saveEntry(plainEntry("swsh7-215"))
        await model.saveEntry(plainEntry("ex6-58"))
        await waitForStreams()
        let first = try XCTUnwrap(model.entries.first { $0.cardId == "swsh7-215" })
        let second = try XCTUnwrap(model.entries.first { $0.cardId == "ex6-58" })

        await model.deleteEntry(id: first.id)
        await model.deleteEntry(id: second.id)
        await waitForStreams()

        await model.undoLastDelete()
        await waitForStreams()

        XCTAssertEqual(model.entries.map(\.cardId), ["ex6-58"])
    }

    /// Regression guard for the toast that never appeared. The 6-second dismissal used to live in
    /// a `.task` on the toast view, and `try? await Task.sleep` swallowed its own CancellationError
    /// — so the instant SwiftUI re-identified that subtree (which the entries stream causes on
    /// every delete), the cancelled sleep fell straight through to the clear and wiped the offer
    /// inside a frame. Deleting is exactly when the stream fires, so the offer never survived its
    /// own delete. Owning the countdown in the model is what fixes it; this asserts the offer
    /// outlives the churn.
    func testUndoOfferSurvivesTheStreamEmissionCausedByItsOwnDelete() async throws {
        await model.saveEntry(plainEntry("swsh7-215"))
        await waitForStreams()
        let entry = try XCTUnwrap(model.entries.first)

        await model.deleteEntry(id: entry.id)
        await waitForStreams()          // the delete's own notify, and then some
        for _ in 0..<50 { await Task.yield() }

        XCTAssertNotNil(model.undoable, "the offer must outlive the delete that raised it")
        XCTAssertEqual(model.undoable?.entries.first?.id, entry.id)
    }

    /// A second delete replaces the offer, and the first one's expired countdown must not then
    /// wipe the newer offer — the same cancellation trap one level up.
    func testASecondDeleteReplacesTheOfferWithoutTheFirstClearingIt() async throws {
        await model.saveEntry(plainEntry("swsh7-215"))
        await model.saveEntry(plainEntry("ex6-58"))
        await waitForStreams()
        let first = try XCTUnwrap(model.entries.first { $0.cardId == "swsh7-215" })
        let second = try XCTUnwrap(model.entries.first { $0.cardId == "ex6-58" })

        await model.deleteEntry(id: first.id)
        await model.deleteEntry(id: second.id)
        await waitForStreams()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(model.undoable?.entries.first?.id, second.id,
                       "the newest delete owns the offer, and the superseded timer must not clear it")
    }

    /// Taking the undo clears the offer and stops its countdown, so a later expiry can't fire
    /// against a state the user already resolved.
    func testTakingTheUndoRetiresTheOffer() async throws {
        await model.saveEntry(plainEntry("swsh7-215"))
        await waitForStreams()
        let entry = try XCTUnwrap(model.entries.first)
        await model.deleteEntry(id: entry.id)
        await waitForStreams()

        await model.undoLastDelete()
        await waitForStreams()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertNil(model.undoable)
        XCTAssertEqual(model.entries.count, 1)
    }

    func testUndoIsANoOpWhenNothingWasDeleted() async throws {
        await model.saveEntry(plainEntry("swsh7-215"))
        await waitForStreams()
        await model.undoLastDelete()
        await waitForStreams()
        XCTAssertEqual(model.entries.count, 1)
    }

    // MARK: Trade list

    /// Reversed 2026-07-25, when the trade list became one row per physical copy: a copy you're
    /// keeping and a copy you'll trade are no longer interchangeable, so they must not fold
    /// together. Without this, the next bulk move would silently merge them and undo the split.
    func testAForTradeCopyDoesNotFoldIntoAKeptCopy() async throws {
        var flagged = plainEntry("swsh7-215")
        flagged.forTrade = true
        await model.saveEntry(flagged)
        await waitForStreams()
        await model.saveEntry(plainEntry("swsh7-215"))   // a kept copy
        await waitForStreams()

        XCTAssertEqual(model.entries.count, 2, "keep and trade are different copies now")
        XCTAssertEqual(model.entries.filter(\.isForTrade).count, 1)
        XCTAssertEqual(model.tradeEntries.count, 1)
    }

    /// Two copies you're BOTH keeping still fold — the duplicate rule is intact for everything
    /// the flag doesn't distinguish.
    func testTwoKeptCopiesStillFold() async throws {
        await model.saveEntry(plainEntry("swsh7-215"))
        await waitForStreams()
        await model.saveEntry(plainEntry("swsh7-215"))
        await waitForStreams()

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.qty, 2)
    }

    /// Trading is a per-copy decision — keep the sharp one, trade the other three — so flagging a
    /// ×4 stack has to produce four rows you can act on individually.
    func testFlaggingDuplicatesSplitsAStackIntoIndividualCopies() async throws {
        await model.saveEntry(plainEntry("swsh7-215", qty: 4))
        await waitForStreams()

        await model.flagDuplicatesForTrade()
        await waitForStreams()

        XCTAssertEqual(model.tradeEntries.count, 4, "one row per physical copy")
        XCTAssertTrue(model.tradeEntries.allSatisfy { $0.qty == 1 })
        XCTAssertEqual(Set(model.tradeEntries.map(\.id)).count, 4, "each copy needs its own id")
        XCTAssertEqual(model.tradeValue.totalCards, 4, "no card is lost or duplicated by the split")
    }

    /// Money on the row is a TOTAL, so splitting must divide it — otherwise a ×4 row bought for
    /// $100 becomes four rows claiming $100 each and the cost basis quadruples.
    func testSplittingDividesTheRecordedCostAcrossCopies() async throws {
        await model.saveEntry(plainEntry("swsh7-215", qty: 4, pricePaid: 100))
        await waitForStreams()

        await model.flagDuplicatesForTrade()
        await waitForStreams()

        let paid = model.tradeEntries.compactMap(\.pricePaid)
        XCTAssertEqual(paid.count, 4)
        XCTAssertEqual(paid.reduce(0, +), 100, accuracy: 0.001, "total cost basis is preserved")
        XCTAssertEqual(paid.first ?? 0, 25, accuracy: 0.001)
    }

    /// Unflagging one copy leaves it in the tin as its own row — "Keep" is not a delete.
    func testKeepingOneCopyLeavesItInTheTin() async throws {
        await model.saveEntry(plainEntry("swsh7-215", qty: 3))
        await waitForStreams()
        await model.flagDuplicatesForTrade()
        await waitForStreams()
        let kept = try XCTUnwrap(model.tradeEntries.first)

        await model.setForTrade(kept, false)
        await waitForStreams()

        XCTAssertEqual(model.tradeEntries.count, 2)
        XCTAssertEqual(model.entries.cardCount, 3, "the kept copy is still yours")
    }

    func testTradeListCollectsFlaggedCopiesAndValuesThem() async throws {
        var flagged = plainEntry("swsh7-215", qty: 2)
        flagged.forTrade = true
        await model.saveEntry(flagged)
        await model.saveEntry(plainEntry("ex6-58"))
        await waitForStreams()

        XCTAssertEqual(model.tradeEntries.count, 1)
        XCTAssertEqual(model.tradeEntries.first?.cardId, "swsh7-215")
        XCTAssertEqual(model.tradeValue.totalCards, 2)   // physical cards, not rows
        XCTAssertEqual(model.tradeValue.total, 185)      // 2 × raw 92.5
    }

    /// Duplicates are counted in physical copies across every row for a card, so two separate
    /// ×1 acquisitions of the same card count as a duplicate even though neither row is ×2.
    func testDuplicatesSpanRowsAndCanBeFlaggedInOneGo() async throws {
        await model.saveEntry(plainEntry("swsh7-215", pricePaid: 10))       // own acquisition…
        await model.saveEntry(plainEntry("swsh7-215", pricePaid: 20))       // …so these stay 2 rows
        await model.saveEntry(plainEntry("ex6-58"))                          // single copy
        await waitForStreams()

        XCTAssertEqual(model.duplicateCardIds, ["swsh7-215"])

        await model.flagDuplicatesForTrade()
        await waitForStreams()

        XCTAssertEqual(Set(model.tradeEntries.map(\.cardId)), ["swsh7-215"])
        XCTAssertEqual(model.tradeEntries.count, 2, "every row of a duplicated card is flagged")
        XCTAssertFalse(model.entries.first { $0.cardId == "ex6-58" }?.isForTrade ?? true)
    }

    func testUnflaggingClearsTheFieldRatherThanStoringFalse() async throws {
        var flagged = plainEntry("swsh7-215")
        flagged.forTrade = true
        await model.saveEntry(flagged)
        await waitForStreams()
        let entry = try XCTUnwrap(model.entries.first)

        await model.setForTrade(entry, false)
        await waitForStreams()

        XCTAssertTrue(model.tradeEntries.isEmpty)
        XCTAssertNil(model.entries.first?.forTrade,
                     "an unmarked entry should look exactly like one that was never marked")
    }

    // MARK: acquisition source (Phase 1 provenance)

    /// Two copies of the same card pulled from the same pack are interchangeable — they must
    /// still fold into a ×2 row, or a pack rip produces one row per card.
    func testPulledCopiesOfTheSameCardAreTheSameCopy() {
        let a = Self.plainEntry(acquiredVia: AcquiredVia.pulled.rawValue)
        let b = Self.plainEntry(acquiredVia: AcquiredVia.pulled.rawValue)
        XCTAssertTrue(a.isSameCopy(as: b))
    }

    /// A pull and a purchase are NOT interchangeable. Merging them destroys the provenance with
    /// nothing to notice it by — the same failure `forTrade` had before it joined this check.
    func testPulledAndBoughtCopiesAreNotTheSameCopy() {
        let pulled = Self.plainEntry(acquiredVia: AcquiredVia.pulled.rawValue)
        let bought = Self.plainEntry(acquiredVia: AcquiredVia.bought.rawValue)
        XCTAssertFalse(pulled.isSameCopy(as: bought))
    }

    /// nil is "not recorded", which is not the same claim as "bought".
    func testUnrecordedAndBoughtCopiesAreNotTheSameCopy() {
        let unknown = Self.plainEntry(acquiredVia: nil)
        let bought = Self.plainEntry(acquiredVia: AcquiredVia.bought.rawValue)
        XCTAssertFalse(unknown.isSameCopy(as: bought))
    }

    /// The source alone is not "acquisition detail" — that gate exists to stop rows with real
    /// per-copy facts (a price, a date, a seller) from being folded away. A bare source label
    /// carries none of those, so it must not block merging.
    func testSourceAloneIsNotAcquisitionDetail() {
        XCTAssertFalse(Self.plainEntry(acquiredVia: AcquiredVia.pulled.rawValue)
            .hasAcquisitionDetail)
    }

    /// THE regression test for the Codable trap: a collection.json written before this field
    /// existed has no `acquiredVia` key. A defaulted non-optional would make Decodable demand
    /// it and every existing file would fail to decode — silently, at restore time.
    func testEntryWrittenBeforeThisFieldStillDecodes() throws {
        let legacy = """
        {"id":"e1","cardId":"swsh7-215","groupId":"","qty":1,"addedAt":770000000}
        """
        let entry = try JSONDecoder().decode(CollectionEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(entry.acquiredVia)
        XCTAssertNil(entry.acquiredViaValue)
        XCTAssertEqual(entry.qty, 1)
    }

    /// An unrecognised rawValue (hand-edited file, newer app version) reads as "not recorded"
    /// rather than crashing or inventing a case.
    func testUnknownSourceRawValueReadsAsNil() {
        XCTAssertNil(Self.plainEntry(acquiredVia: "ripped-from-a-cereal-box").acquiredViaValue)
    }

    private static func plainEntry(acquiredVia: String?) -> CollectionEntry {
        CollectionEntry(id: UUID().uuidString, cardId: "swsh7-215", groupId: "", qty: 1,
                        condition: "NM", grade: nil, pricePaid: nil, acquiredAt: nil,
                        acquiredFrom: nil, addedAt: Date(), variant: "regular",
                        acquiredVia: acquiredVia)
    }
}
