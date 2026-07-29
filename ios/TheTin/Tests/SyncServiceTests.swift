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

    func start() async throws {
        if let startError { throw startError }
        started = true
    }
    func stop() { started = false }
    func send(upserts: [SyncRecord], deletes: [SyncRecord]) {
        sentUpserts += upserts
        sentDeletes += deletes
    }
    func fetchAll() async throws -> [SyncRecord] { zone }

    func reset() { sentUpserts = []; sentDeletes = [] }
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
                             collection: InMemoryCollectionRepository? = nil,
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

    /// The `syncSeeded` flag is what stops a second launch re-asking or silently replacing.
    func testAlreadySeededDeviceNeitherAsksNorReplaces() async throws {
        defaults.set(true, forKey: SyncService.seededKey)
        let collection = InMemoryCollectionRepository()
        try await collection.addEntry(entry("local1"))
        let engine = FakeSyncEngine()
        engine.zone = [try SyncRecord.entry(entry("remote1"))]
        let service = makeService(engine: engine, collection: collection)

        await service.start()

        XCTAssertNil(service.seedPrompt)
        XCTAssertEqual(collection.entries.map(\.id), ["local1"])
        XCTAssertTrue(engine.sentUpserts.isEmpty)
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

    private func entry(_ id: String) -> CollectionEntry {
        CollectionEntry(id: id, cardId: "base1-4", groupId: "", qty: 1,
                        addedAt: Date(timeIntervalSince1970: 0))
    }
}
