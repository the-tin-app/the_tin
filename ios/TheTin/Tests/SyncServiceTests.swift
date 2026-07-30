import XCTest
@testable import TheTin

/// Stands in for `CKSyncEngine`. Records what was queued and can push records back the other way,
/// which is the whole point of the seam: every decision in `SyncService` is exercised here with no
/// CloudKit, no account, and no second device.
private final class FakeSyncEngine: SyncEngine, @unchecked Sendable {
    var onRemoteChange: (@Sendable ([SyncRecord], [SyncRecord]) -> Void)?
    var onStatus: (@Sendable (SyncStatus) -> Void)?

    var zone: [SyncRecord] = []
    var sentUpserts: [SyncRecord] = []
    var sentDeletes: [SyncRecord] = []
    var started = false
    var startError: Error?
    var fetchAllError: Error?
    var fetchChangesCalls = 0
    /// Stands in for `CKSyncEngine.State.pendingRecordZoneChanges` — what this device still owes the
    /// zone, and therefore must never interpret the zone's silence about as a deletion.
    var pendingKeys: Set<String> = []

    /// Delivered from inside `start()`, reproducing `CKSyncEngine` fetching the moment it exists.
    var deliverDuringStart: ([SyncRecord], [SyncRecord])?

    func start() async throws {
        if let startError { throw startError }
        started = true
        if let (upserts, deletes) = deliverDuringStart { onRemoteChange?(upserts, deletes) }
    }
    func stop() { started = false }
    func fetchChanges() async { fetchChangesCalls += 1 }
    func send(upserts: [SyncRecord], deletes: [SyncRecord]) {
        sentUpserts += upserts
        sentDeletes += deletes
    }
    func fetchAll() async throws -> [SyncRecord] {
        if let fetchAllError { throw fetchAllError }
        return zone
    }

    func reset() { sentUpserts = []; sentDeletes = [] }
}

/// An in-memory repository whose `replaceAll` fails — a full disk, which this Mac hit for real
/// while this branch was being built, and which is exactly when `replaceAll` throws.
@MainActor
private final class FailingReplaceAllRepository: CollectionRepository {
    struct WriteFailed: Error {}
    private let inner = InMemoryCollectionRepository()
    var entries: [CollectionEntry] { inner.entries }

    func replaceAll(groups: [CardGroup], entries: [CollectionEntry],
                    sealed: [SealedEntry]) async throws {
        throw WriteFailed()
    }

    nonisolated func groupsStream() -> AsyncStream<[CardGroup]> { inner.groupsStream() }
    nonisolated func entriesStream() -> AsyncStream<[CollectionEntry]> { inner.entriesStream() }
    nonisolated func sealedStream() -> AsyncStream<[SealedEntry]> { inner.sealedStream() }
    func addSealed(_ entry: SealedEntry) async throws { try await inner.addSealed(entry) }
    func updateSealed(_ entry: SealedEntry) async throws { try await inner.updateSealed(entry) }
    func deleteSealed(id: String) async throws { try await inner.deleteSealed(id: id) }
    func createGroup(name: String) async throws -> String { try await inner.createGroup(name: name) }
    func renameGroup(id: String, name: String) async throws { try await inner.renameGroup(id: id, name: name) }
    func deleteGroup(id: String, keepingEntries: Bool) async throws {
        try await inner.deleteGroup(id: id, keepingEntries: keepingEntries)
    }
    func reorderGroups(orderedIds: [String]) async throws { try await inner.reorderGroups(orderedIds: orderedIds) }
    func addEntry(_ entry: CollectionEntry) async throws { try await inner.addEntry(entry) }
    func addEntries(_ entries: [CollectionEntry]) async throws { try await inner.addEntries(entries) }
    func updateEntry(_ entry: CollectionEntry) async throws { try await inner.updateEntry(entry) }
    func applyEntryEdits(updated: [CollectionEntry], deletedIds: [String]) async throws {
        try await inner.applyEntryEdits(updated: updated, deletedIds: deletedIds)
    }
    func deleteEntry(id: String) async throws { try await inner.deleteEntry(id: id) }
}

@MainActor
final class SyncServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// `AppConfig.syncEnabled` lives in `UserDefaults.standard`, which outlives the process — a
    /// test that leaves it flipped fails a DIFFERENT test on the NEXT run. Pinned in setUp AND
    /// tearDown.
    private var savedSyncEnabled: Bool!

    override func setUp() {
        super.setUp()
        savedSyncEnabled = AppConfig.syncEnabled
        AppConfig.syncEnabled = true
        suiteName = "SyncServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        AppConfig.syncEnabled = savedSyncEnabled
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // Defaults are nil rather than `.init()`: a default argument is evaluated in a nonisolated
    // context, and `InMemoryCollectionRepository` is @MainActor.
    private func makeService(engine: FakeSyncEngine?,
                             collection: CollectionRepository? = nil,
                             wants: InMemoryWantsRepository? = nil) -> SyncService {
        SyncService(engine: engine,
                    collection: collection ?? InMemoryCollectionRepository(),
                    wants: wants ?? InMemoryWantsRepository(),
                    uid: "local", defaults: defaults)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(120)) }

    // MARK: Degradation

    /// The entitlement is deliberately NOT applied yet, so `makeEngine()` returns nil in every
    /// build that exists today. That path must be indistinguishable from signed-out.
    func testNoEngineReportsUnavailableAndTouchesNothing() async {
        let collection = InMemoryCollectionRepository()
        let service = makeService(engine: nil, collection: collection)
        await service.start()
        XCTAssertEqual(service.status, .unavailable)
        XCTAssertNil(service.seedPrompt)
        XCTAssertTrue(collection.entries.isEmpty)
    }

    func testDisabledToggleNeverStartsTheEngine() async {
        AppConfig.syncEnabled = false
        let engine = FakeSyncEngine()
        await makeService(engine: engine).start()
        XCTAssertFalse(engine.started)
    }

    func testEngineStartFailureDegradesToUnavailable() async {
        let engine = FakeSyncEngine()
        engine.startError = CocoaError(.fileNoSuchFile)
        let service = makeService(engine: engine)
        await service.start()
        XCTAssertEqual(service.status, .unavailable)
    }

    /// A remote event delivered while `start()` is still running must NOT be dropped.
    ///
    /// `CKSyncEngine` can fetch the moment it is constructed, and the handler used to be attached
    /// later, in `subscribe()`. Anything arriving in that gap hit a nil closure and vanished —
    /// while the engine's change token advanced regardless, so the feed never replayed it, and
    /// `fetchAll` cannot express a deletion. The record stayed on this device forever.
    /// Confirmed on two real devices 2026-07-29.
    func testRemoteDeleteDuringStartIsNotLost() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("doomed"))
        let engine = FakeSyncEngine()
        engine.zone = []
        engine.deliverDuringStart = ([], [SyncRecord(type: .entry, recordName: "doomed",
                                                     payload: nil)])
        let service = makeService(engine: engine, collection: collection)

        await service.start()
        try await settle()

        XCTAssertTrue(collection.entries.isEmpty,
                      "delete arrived mid-start and must survive to be applied")
    }

    /// An unreadable zone is NOT an empty zone. Conflating them let one transient CloudKit error
    /// on first run mark the device seeded and skip the "which device wins?" sheet forever —
    /// silently, and permanently. It must report `.failed`, decide nothing, and seed nothing.
    func testUnreadableZoneNeitherSeedsNorClaimsSuccess() async throws {
        let engine = FakeSyncEngine()
        engine.fetchAllError = CocoaError(.fileReadUnknown)
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("local1"))
        let service = makeService(engine: engine, collection: collection)

        await service.start()
        try await settle()

        XCTAssertEqual(service.status, .failed, "a fetch that threw must not report .synced")
        XCTAssertFalse(defaults.bool(forKey: SyncService.seededKey), "must not mark seeded blind")
        XCTAssertTrue(engine.sentUpserts.isEmpty, "must not seed the zone from an unread zone")
        XCTAssertNil(service.seedPrompt)
    }

    /// ...and it must be recoverable. Nothing is subscribed after a failed zone read, so without
    /// this the first bad launch leaves sync dead until the user relaunches the app.
    func testForegroundRetriesAfterAFailedZoneRead() async throws {
        let engine = FakeSyncEngine()
        engine.fetchAllError = CocoaError(.fileReadUnknown)
        let service = makeService(engine: engine)
        await service.start()
        try await settle()
        XCTAssertEqual(service.status, .failed)

        engine.fetchAllError = nil          // the network comes back
        await service.refresh()
        try await settle()
        XCTAssertNotEqual(service.status, .failed, "a foreground must retry the failed start")
        XCTAssertTrue(defaults.bool(forKey: SyncService.seededKey))
    }

    // MARK: Foreground refresh

    /// The foreground catch-up must go through the engine's CHANGE FEED, not another `fetchAll`.
    /// `fetchAll` reports which records exist, and absence is not a delete — so it structurally
    /// cannot carry a deletion. Confirmed on device 2026-07-29: a delete on one device survived
    /// two relaunches on the other, because the feed only fires for push and for local pending
    /// changes, and a device that merely sat there has neither.
    func testForegroundRefreshPullsTheChangeFeed() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let engine = FakeSyncEngine()
        let service = makeService(engine: engine)
        await service.start()
        try await settle()
        // A cold launch must pull the feed too: `fetchAll` carries upserts only, and
        // `.onChange(of: scenePhase)` never fires for the INITIAL `.active`, so a launch is not
        // covered by `refresh()`. Without this a remote delete survives the whole session.
        XCTAssertEqual(engine.fetchChangesCalls, 1, "cold launch must pull the change feed")

        await service.refresh()
        XCTAssertEqual(engine.fetchChangesCalls, 2, "every foreground pulls it again")
    }

    /// Before the seed choice is answered there is nothing safe to pull: subscribing the zone into
    /// a device whose choice is still open merges the two collections the sheet is asking the user
    /// to pick between. A foreground while that sheet is up must do nothing at all.
    func testForegroundRefreshDoesNothingBeforeSeeding() async throws {
        let engine = FakeSyncEngine()
        engine.zone = [try SyncRecord.entry(entry("remote1"))]
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("local1"))
        let service = makeService(engine: engine, collection: collection)
        await service.start()
        try await settle()

        XCTAssertNotNil(service.seedPrompt, "precondition: the choice sheet is up")
        await service.refresh()
        XCTAssertEqual(engine.fetchChangesCalls, 0)
    }

    // MARK: Seeding

    func testEmptyZoneSeedsFromLocal() async throws {
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("e1"))
        let engine = FakeSyncEngine()
        let service = makeService(engine: engine, collection: collection)

        await service.start()

        XCTAssertEqual(engine.sentUpserts.filter { $0.type == .entry }.map(\.recordName), ["e1"])
        XCTAssertTrue(defaults.bool(forKey: SyncService.seededKey))
        XCTAssertNil(service.seedPrompt)
    }

    func testEmptyLocalPullsTheZoneDown() async throws {
        let collection = InMemoryCollectionRepository()
        let engine = FakeSyncEngine()
        engine.zone = [try SyncRecord.entry(entry("remote1"))]
        let service = makeService(engine: engine, collection: collection)

        await service.start()

        XCTAssertEqual(collection.entries.map(\.id), ["remote1"])
        XCTAssertTrue(defaults.bool(forKey: SyncService.seededKey))
    }

    func testDivergentCollectionsAskAndSubscribeToNothingUntilAnswered() async throws {
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("local1"))
        let engine = FakeSyncEngine()
        engine.zone = [try SyncRecord.entry(entry("remote1")),
                       try SyncRecord.entry(entry("remote2"))]
        let service = makeService(engine: engine, collection: collection)

        await service.start()

        XCTAssertEqual(service.seedPrompt, SeedPrompt(localCount: 1, remoteCount: 2))
        XCTAssertFalse(defaults.bool(forKey: SyncService.seededKey))
        // Nothing may cross until the user chooses — merging the two is the one answer the
        // sheet is asking them NOT to have imposed on them.
        engine.reset()
        try await collection.addEntry(entry("local2"))
        try await settle()
        XCTAssertTrue(engine.sentUpserts.isEmpty)
        XCTAssertEqual(collection.entries.count, 2)   // still purely local
    }

    func testChoosingRemoteReplacesLocal() async throws {
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("local1"))
        let engine = FakeSyncEngine()
        engine.zone = [try SyncRecord.entry(entry("remote1"))]
        let service = makeService(engine: engine, collection: collection)
        await service.start()

        await service.resolveSeed(useLocal: false)

        XCTAssertEqual(collection.entries.map(\.id), ["remote1"])
        XCTAssertNil(service.seedPrompt)
        XCTAssertTrue(defaults.bool(forKey: SyncService.seededKey))
    }

    func testChoosingLocalReplacesTheZone() async throws {
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("local1"))
        let engine = FakeSyncEngine()
        engine.zone = [try SyncRecord.entry(entry("remote1"))]
        let service = makeService(engine: engine, collection: collection)
        await service.start()
        engine.reset()

        await service.resolveSeed(useLocal: true)

        XCTAssertEqual(collection.entries.map(\.id), ["local1"])
        XCTAssertEqual(engine.sentUpserts.filter { $0.type == .entry }.map(\.recordName), ["local1"])
        XCTAssertEqual(engine.sentDeletes.map(\.recordName), ["remote1"])
    }

    /// The `syncSeeded` flag stops a second launch re-asking or silently replacing — but the
    /// device must still MERGE what the zone holds.
    ///
    /// This previously asserted the opposite, that `remote1` was dropped. That is the behaviour
    /// which shipped and then failed on two real devices: `automaticallySync` reacts only to local
    /// pending changes and to push, so a device with neither never fetches on its own, and
    /// `start()`'s own `fetchAll()` result was discarded on this branch. A card added on the iPad
    /// never reached the iPhone, even across relaunches (found 2026-07-29).
    ///
    /// Merge, not replace — `local1` survives. And the echo guard holds: `remote1` arrived FROM
    /// the zone, so only `local1` is pushed back up.
    func testAlreadySeededDeviceMergesRemoteAndPushesOnlyLocal() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("local1"))
        let engine = FakeSyncEngine()
        engine.zone = [try SyncRecord.entry(entry("remote1"))]
        let service = makeService(engine: engine, collection: collection)

        await service.start()

        XCTAssertNil(service.seedPrompt)
        XCTAssertEqual(collection.entries.map(\.id).sorted(), ["local1", "remote1"])
        // Nothing is pushed on launch: the first stream emission after `start()` is seed-only, so
        // it populates the hash map without re-pushing the whole collection. `local1` therefore
        // stays local until something changes it.
        //
        // ⚠️ That leaves a narrow hole, deliberately recorded rather than silently patched: a
        // record created while the sync TOGGLE WAS OFF is never subscribed, so it is never pushed,
        // and turning sync back on seeds it into the hash map as already-known. It reaches the zone
        // only if it is edited again. See the handoff doc, §4.
        XCTAssertTrue(engine.sentUpserts.isEmpty)
    }

    // MARK: Reconcile — the second delivery path for a deletion

    /// The bug this exists for. A record this device HAS seen in the zone, now gone from it, with
    /// nothing pending, was deleted elsewhere — and the change feed is once-only, so if its event
    /// was missed there is no other way to learn. Measured on device 2026-07-29: an iPad held 59
    /// entries against the zone's 58 and stayed diverged through three fetch cycles, a
    /// pull-to-refresh and a relaunch.
    func testARecordSeenInTheZoneAndThenMissingIsDeletedLocally() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("keep"))
        try await collection.addEntry(entry("gone"))

        // First launch: both records are in the zone, so both become "known remote".
        let first = FakeSyncEngine()
        first.zone = [try SyncRecord.entry(entry("keep")), try SyncRecord.entry(entry("gone"))]
        await makeService(engine: first, collection: collection).start()

        // Second launch: the other device deleted "gone", and its feed event never arrived.
        let second = FakeSyncEngine()
        second.zone = [try SyncRecord.entry(entry("keep"))]
        await makeService(engine: second, collection: collection).start()

        XCTAssertEqual(collection.entries.map(\.id), ["keep"],
                       "a record deleted elsewhere must not survive forever just because its feed event was missed")
    }

    /// A record this device has NEVER seen in the zone was never uploaded — added while the sync
    /// toggle was off, or a send that failed for good. Absence from the zone is not evidence it was
    /// deleted, and erasing it would destroy a card the user added.
    func testARecordNeverSeenInTheZoneIsNotDeleted() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("neverUploaded"))
        let engine = FakeSyncEngine()
        engine.zone = [try SyncRecord.entry(entry("somethingElse"))]

        await makeService(engine: engine, collection: collection).start()

        XCTAssertTrue(collection.entries.contains { $0.id == "neverUploaded" },
                      "never having reached the zone is not the same as having been deleted from it")
    }

    /// Queued locally and not sent yet — the exact case that made this approach look too dangerous
    /// to attempt. `pendingKeys` is what makes it safe.
    func testAPendingRecordIsNotDeletedEvenIfPreviouslySeen() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("queued"))
        let first = FakeSyncEngine()
        first.zone = [try SyncRecord.entry(entry("queued")), try SyncRecord.entry(entry("other"))]
        await makeService(engine: first, collection: collection).start()

        let second = FakeSyncEngine()
        second.zone = [try SyncRecord.entry(entry("other"))]
        second.pendingKeys = [try SyncRecord.entry(entry("queued")).key]
        await makeService(engine: second, collection: collection).start()

        XCTAssertTrue(collection.entries.contains { $0.id == "queued" },
                      "an unsent local change must never be read as a remote deletion")
    }

    /// A wiped or recreated zone must never be read as "the user deleted everything". A genuine mass
    /// delete arrives through the change feed, which says so explicitly.
    func testAnEmptyZoneNeverDeletesAnything() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("a"))
        try await collection.addEntry(entry("b"))
        let first = FakeSyncEngine()
        first.zone = [try SyncRecord.entry(entry("a")), try SyncRecord.entry(entry("b"))]
        await makeService(engine: first, collection: collection).start()

        let second = FakeSyncEngine()
        second.zone = []
        await makeService(engine: second, collection: collection).start()

        XCTAssertEqual(collection.entries.count, 2,
                       "an empty zone is not permission to empty the collection")
    }

    /// A PULL heals; a foreground does not. The gesture means "I know something changed", so it pays
    /// for a whole-zone read; an `.active` transition happens constantly and must stay cheap.
    func testPullReconcilesButForegroundDoesNot() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("keep"))
        try await collection.addEntry(entry("gone"))
        let first = FakeSyncEngine()
        first.zone = [try SyncRecord.entry(entry("keep")), try SyncRecord.entry(entry("gone"))]
        await makeService(engine: first, collection: collection).start()

        // A second session, subscribed, with "gone" no longer in the zone and its feed event missed.
        let engine = FakeSyncEngine()
        engine.zone = [try SyncRecord.entry(entry("keep")),
                       try SyncRecord.entry(entry("gone"))]
        let service = makeService(engine: engine, collection: collection)
        await service.start()
        try await settle()
        engine.zone = [try SyncRecord.entry(entry("keep"))]

        await service.refresh()
        try await settle()
        XCTAssertTrue(collection.entries.contains { $0.id == "gone" },
                      "a plain foreground must not pay for a whole-zone read")

        await service.refresh(reconcile: true)
        try await settle()
        XCTAssertEqual(collection.entries.map(\.id), ["keep"],
                       "pulling down is exactly when a stranded deletion should be healed")
    }

    // MARK: Live operation

    func testLocalMutationsPushAndDeletesPropagate() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("e1"))
        let engine = FakeSyncEngine()
        let service = makeService(engine: engine, collection: collection)
        await service.start()
        try await settle()
        // The first emission of each stream seeds the hash map and pushes nothing.
        XCTAssertTrue(engine.sentUpserts.isEmpty)

        try await collection.addEntry(entry("e2"))
        try await settle()
        XCTAssertEqual(engine.sentUpserts.filter { $0.type == .entry }.map(\.recordName), ["e2"])

        engine.reset()
        try await collection.deleteEntry(id: "e1")
        try await settle()
        XCTAssertEqual(engine.sentDeletes.map(\.recordName), ["e1"])
    }

    /// The echo guard, end to end: applying a remote record writes to the repository, which
    /// notifies, which diffs — and without the map being updated at apply time would push it
    /// straight back forever.
    func testAppliedRemoteRecordIsNotPushedBack() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("e1"))
        let engine = FakeSyncEngine()
        let service = makeService(engine: engine, collection: collection)
        await service.start()
        try await settle()
        engine.reset()

        engine.onRemoteChange?([try SyncRecord.entry(entry("fromOtherDevice"))], [])
        try await settle()

        XCTAssertEqual(Set(collection.entries.map(\.id)), ["e1", "fromOtherDevice"])
        XCTAssertTrue(engine.sentUpserts.isEmpty, "the applied record was echoed back to CloudKit")
        XCTAssertTrue(engine.sentDeletes.isEmpty)
    }

    func testRemoteDeleteIsAppliedAndNotEchoed() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("e1"))
        try await collection.addEntry(entry("e2"))
        let engine = FakeSyncEngine()
        let service = makeService(engine: engine, collection: collection)
        await service.start()
        try await settle()
        engine.reset()

        engine.onRemoteChange?([], [SyncRecord(type: .entry, recordName: "e2", payload: nil)])
        try await settle()

        XCTAssertEqual(collection.entries.map(\.id), ["e1"])
        XCTAssertTrue(engine.sentUpserts.isEmpty)
        XCTAssertTrue(engine.sentDeletes.isEmpty)
    }

    /// A failed local write must NOT be reported as synced, and must not leave the hash map
    /// claiming local matches remote.
    ///
    /// The echo guard folds incoming records into the map before the write (correctly — that is
    /// what stops the push-back loop). If the write then fails and the fold stands, the service
    /// believes the record is settled: it is never re-applied and never re-pushed, so the incoming
    /// card is silently eaten. `LocalCollectionRepository.mutate` rolls back and throws before
    /// `notify()` specifically so nothing observes state that isn't on disk; this proves the sync
    /// layer honours that rather than discarding it.
    func testFailedLocalWriteReportsFailureAndDoesNotSettleTheRecord() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = FailingReplaceAllRepository()
        try await collection.addEntry(entry("e1"))
        let engine = FakeSyncEngine()
        let service = makeService(engine: engine, collection: collection)
        await service.start()
        try await settle()
        engine.reset()

        engine.onRemoteChange?([try SyncRecord.entry(entry("fromOtherDevice"))], [])
        try await settle()

        XCTAssertEqual(service.status, .failed, "a write that threw must not report as synced")
        XCTAssertEqual(collection.entries.map(\.id), ["e1"])   // the write really didn't land

        // The hash map must not have kept the record. If it had, this next local emission would
        // diff a map holding "fromOtherDevice" against a collection that doesn't, and push a
        // DELETE — telling the other device to destroy the card it had just sent.
        try await collection.addEntry(entry("e2"))
        try await settle()
        XCTAssertTrue(engine.sentDeletes.isEmpty,
                      "a failed apply was treated as settled and pushed a phantom delete")
        XCTAssertEqual(engine.sentUpserts.map(\.recordName), ["e2"])
    }

    /// Wishlist edits ride the same path as the collection.
    func testWantsSyncBothWays() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let wants = InMemoryWantsRepository()
        let engine = FakeSyncEngine()
        let service = makeService(engine: engine, wants: wants)
        await service.start()
        try await settle()
        engine.reset()

        try await wants.save(uid: "local", entries: ["sv1-25": WantEntry(priority: .high)])
        try await settle()
        XCTAssertEqual(engine.sentUpserts.filter { $0.type == .want }.map(\.recordName), ["sv1-25"])

        engine.reset()
        engine.onRemoteChange?([try SyncRecord.want(cardId: "base1-4", WantEntry())], [])
        try await settle()
        XCTAssertEqual(Set(wants.stored.keys), ["sv1-25", "base1-4"])
        XCTAssertTrue(engine.sentUpserts.isEmpty)
    }

    func testTurningTheToggleOffStopsSyncing() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        let engine = FakeSyncEngine()
        let service = makeService(engine: engine, collection: collection)
        await service.start()
        try await settle()

        await service.setEnabled(false)
        engine.reset()
        try await collection.addEntry(entry("afterOff"))
        try await settle()

        XCTAssertEqual(service.status, .unavailable)
        XCTAssertFalse(AppConfig.syncEnabled)
        XCTAssertTrue(engine.sentUpserts.isEmpty)
        XCTAssertEqual(collection.entries.map(\.id), ["afterOff"])   // local keeps working
    }

    // MARK: Sealed products

    /// Sealed has its own stream and its own record type, so it needs its own proof that a local
    /// change reaches the zone. Until this branch it was `case .sealed: continue` on both sides —
    /// a user with sealed inventory had it on one device and nothing said so.
    func testLocalSealedMutationsPushAndDeletesPropagate() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addSealed(sealed("s1"))
        let engine = FakeSyncEngine()
        let service = makeService(engine: engine, collection: collection)
        await service.start()
        try await settle()
        XCTAssertTrue(engine.sentUpserts.isEmpty, "the first emission seeds the map and pushes nothing")

        try await collection.addSealed(sealed("s2", productId: 620024))
        try await settle()
        XCTAssertEqual(engine.sentUpserts.filter { $0.type == .sealed }.map(\.recordName), ["s2"])

        engine.reset()
        try await collection.deleteSealed(id: "s1")
        try await settle()
        XCTAssertEqual(engine.sentDeletes.filter { $0.type == .sealed }.map(\.recordName), ["s1"])
    }

    /// The receive half. A sealed record from the other device has to land in the repository, and
    /// a sealed deletion has to remove it — `replaceAll` writes groups, entries and sealed as one
    /// file, so getting this wrong doesn't just drop a box, it can take the cards with it.
    func testRemoteSealedRecordIsAppliedAndDeleted() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("e1"))
        let engine = FakeSyncEngine()
        let service = makeService(engine: engine, collection: collection)
        await service.start()
        try await settle()

        engine.onRemoteChange?([try SyncRecord.sealed(sealed("fromOtherDevice"))], [])
        try await settle()
        XCTAssertEqual(collection.sealed.map(\.id), ["fromOtherDevice"])
        XCTAssertEqual(collection.entries.map(\.id), ["e1"], "the cards must survive a sealed write")

        engine.onRemoteChange?([], [try SyncRecord.sealed(sealed("fromOtherDevice"))])
        try await settle()
        XCTAssertTrue(collection.sealed.isEmpty)
        XCTAssertEqual(collection.entries.map(\.id), ["e1"])
    }

    /// The dangerous direction: a CARD arriving from the other device must not take the sealed
    /// products with it. `replaceAll` rewrites groups, entries and sealed as one file, so an apply
    /// path that rebuilt the file from the records in the batch alone would silently empty the
    /// sealed section every time a card synced. Same trap `replaceAll`'s own doc comment names,
    /// and the reason `sealed` is read here even when no sealed record is in the batch.
    func testApplyingACardDoesNotDeleteSealedProducts() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addSealed(sealed("s1"))
        let engine = FakeSyncEngine()
        let service = makeService(engine: engine, collection: collection)
        await service.start()
        try await settle()

        engine.onRemoteChange?([try SyncRecord.entry(entry("fromOtherDevice"))], [])
        try await settle()

        XCTAssertEqual(collection.entries.map(\.id), ["fromOtherDevice"])
        XCTAssertEqual(collection.sealed.map(\.id), ["s1"], "a card sync must not empty the tin's sealed section")
    }

    /// Seeding an empty zone must carry sealed too. This is really a test of `currentRecords()`,
    /// which is also what `vanished` diffs against — so a sealed product missing from it would
    /// both fail to seed AND be invisible to the deletion reconcile.
    func testSeedingAnEmptyZoneCarriesSealedProducts() async throws {
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("e1"))
        try await collection.addSealed(sealed("s1"))
        let engine = FakeSyncEngine()
        let service = makeService(engine: engine, collection: collection)
        await service.start()
        try await settle()

        XCTAssertEqual(engine.sentUpserts.filter { $0.type == .sealed }.map(\.recordName), ["s1"])
    }

    private func entry(_ id: String) -> CollectionEntry {
        CollectionEntry(id: id, cardId: "base1-4", groupId: "", qty: 1,
                        addedAt: Date(timeIntervalSince1970: 0))
    }

    private func sealed(_ id: String, productId: Int = 598488, qty: Int = 1) -> SealedEntry {
        SealedEntry(id: id, productId: productId, qty: qty,
                    addedAt: Date(timeIntervalSince1970: 0))
    }
}
