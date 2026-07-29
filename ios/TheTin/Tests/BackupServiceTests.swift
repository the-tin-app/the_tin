import XCTest
@testable import TheTin

/// Plain-FileManager BackupStore over a temp dir — exercises BackupService logic without iCloud.
private struct TempDirBackupStore: BackupStore {
    let dir: URL
    func containerURL() -> URL? { dir }
    func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    func rotate(_ url: URL, to prev: URL) {
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: url, to: prev)
    }
    func requestDownload(_ url: URL) {}
}

@MainActor
final class BackupServiceTests: XCTestCase {
    private var dir: URL!
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A collection + wants repository pair persisting under `<dir>/<sub>/` (Paths injection,
    /// same pattern as LocalCollectionRepositoryTests).
    private func makeRepos(sub: String) throws -> (LocalCollectionRepository, LocalWantsRepository) {
        let base = dir.appendingPathComponent(sub, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (LocalCollectionRepository(paths: CollectionPaths(fileURL: base.appendingPathComponent("collection.json"))),
                LocalWantsRepository(paths: WantsPaths(fileURL: base.appendingPathComponent("wants.json"))))
    }

    private func makeService(collection: LocalCollectionRepository, wants: LocalWantsRepository,
                             setGoals: SetGoalsModel? = nil,
                             debounce: Duration = .seconds(5)) -> BackupService {
        BackupService(store: TempDirBackupStore(dir: dir.appendingPathComponent("icloud", isDirectory: true)),
                      collection: collection, wants: wants, setGoals: setGoals, uid: "local",
                      debounce: debounce, now: { self.fixedNow })
    }

    /// A goals model persisting under `<dir>/<sub>/set-goals.json`.
    private func makeGoals(sub: String) -> SetGoalsModel {
        SetGoalsModel(paths: SetGoalPaths(fileURL: dir.appendingPathComponent(sub, isDirectory: true)
            .appendingPathComponent("set-goals.json")))
    }

    /// Whole-second dates: ISO-8601 truncates fractional seconds, and these must round-trip.
    private func fixtureEntry(id: String, groupId: String) -> CollectionEntry {
        CollectionEntry(id: id, cardId: "ex6-58", groupId: groupId, qty: 2,
                        condition: "NM", grade: "psa10", pricePaid: 12.5,
                        acquiredAt: Date(timeIntervalSince1970: 86_400),
                        acquiredFrom: "card show", addedAt: Date(timeIntervalSince1970: 0),
                        variant: "holo")
    }

    private func firstValue<T>(_ stream: AsyncStream<T>) async -> T? {
        for await v in stream { return v }
        return nil
    }

    func testSnapshotEncodeDecodeRoundTripAndRotation() async throws {
        let (col, wants) = try makeRepos(sub: "deviceA")
        let gid = try await col.createGroup(name: "Binder")
        let entry = fixtureEntry(id: "e1", groupId: gid)
        try await col.addEntry(entry)
        try await wants.save(uid: "local", entries: ["sv1-25": WantEntry()])

        let goals = makeGoals(sub: "deviceA")
        goals.toggle("base1")
        let service = makeService(collection: col, wants: wants, setGoals: goals)
        await service.backUpNow()
        XCTAssertEqual(service.status, .backedUp(fixedNow))

        let snapshot = try await service.loadBackup()
        XCTAssertEqual(snapshot.schemaVersion, 4)
        XCTAssertEqual(snapshot.setGoals, ["base1"])
        XCTAssertEqual(snapshot.exportedAt, fixedNow)
        XCTAssertEqual(snapshot.groups.map(\.id), [gid])
        XCTAssertEqual(snapshot.entries, [entry])   // full Codable round-trip, field by field
        XCTAssertEqual(snapshot.wanted, ["sv1-25"])
        XCTAssertNotNil(snapshot.wantEntries?["sv1-25"])

        // Two-slot rotation: a second write moves the previous snapshot to the .prev slot.
        await service.backUpNow()
        let prev = dir.appendingPathComponent("icloud", isDirectory: true)
            .appendingPathComponent(BackupService.prevFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prev.path))
    }

    func testRestoreEligibilityMatrix() {
        // eligible: empty local × non-empty backup
        XCTAssertTrue(BackupService.restoreEligible(localEntryCount: 0, localWantCount: 0, backupEntryCount: 5))
        // any local data blocks auto-restore
        XCTAssertFalse(BackupService.restoreEligible(localEntryCount: 1, localWantCount: 0, backupEntryCount: 5))
        XCTAssertFalse(BackupService.restoreEligible(localEntryCount: 0, localWantCount: 1, backupEntryCount: 5))
        XCTAssertFalse(BackupService.restoreEligible(localEntryCount: 3, localWantCount: 2, backupEntryCount: 5))
        // empty backup / missing-or-undecodable backup (nil) never restores
        XCTAssertFalse(BackupService.restoreEligible(localEntryCount: 0, localWantCount: 0, backupEntryCount: 0))
        XCTAssertFalse(BackupService.restoreEligible(localEntryCount: 0, localWantCount: 0, backupEntryCount: nil))
    }

    func testBackupUnavailableWhenNoContainer() async {
        struct NoContainerStore: BackupStore {
            func containerURL() -> URL? { nil }
            func read(_ url: URL) throws -> Data { throw BackupError.missing }
            func write(_ data: Data, to url: URL) throws {}
            func rotate(_ url: URL, to prev: URL) {}
            func requestDownload(_ url: URL) {}
        }
        let (col, wants) = try! makeRepos(sub: "deviceA")
        let service = BackupService(store: NoContainerStore(), collection: col, wants: wants,
                                    uid: "local", debounce: .seconds(5), now: { self.fixedNow })
        await service.backUpNow()
        XCTAssertEqual(service.status, .unavailable)   // skipped silently, status recorded
    }

    func testRestoreWritesThroughRepositoriesAndOffersOnlyWhenEmpty() async throws {
        // Seed "device A" and back it up.
        let (colA, wantsA) = try makeRepos(sub: "deviceA")
        let gid = try await colA.createGroup(name: "Binder")
        let entry = fixtureEntry(id: "e1", groupId: gid)
        try await colA.addEntry(entry)
        try await wantsA.save(uid: "local", entries:
            ["sv1-25": WantEntry(priority: .high, targetUsd: 25, notes: "grail")])
        await makeService(collection: colA, wants: wantsA).backUpNow()

        // Empty "device B": the launch check offers the restore.
        let (colB, wantsB) = try makeRepos(sub: "deviceB")
        let serviceB = makeService(collection: colB, wants: wantsB)
        await serviceB.offerRestoreIfEligible()
        XCTAssertEqual(serviceB.restoreOffer,
                       BackupService.RestoreOffer(entryCount: 1, exportedAt: fixedNow))

        // Accept → repositories hold the backup (ids preserved), persisted to disk.
        await serviceB.acceptRestore(serviceB.restoreOffer!)
        XCTAssertNil(serviceB.restoreOffer)
        let groups = await firstValue(colB.groupsStream()) ?? []
        let entries = await firstValue(colB.entriesStream()) ?? []
        let wanted = await firstValue(wantsB.stream(uid: "local")) ?? [:]
        XCTAssertEqual(groups.map(\.id), [gid])
        XCTAssertEqual(entries, [entry])
        XCTAssertEqual(Set(wanted.keys), ["sv1-25"])
        // Rich fields (priority/target/notes) survive the encode → decode → restore round trip,
        // not just the id.
        XCTAssertEqual(wanted["sv1-25"]?.priority, .high)
        XCTAssertEqual(wanted["sv1-25"]?.targetUsd, 25)
        XCTAssertEqual(wanted["sv1-25"]?.notes, "grail")

        // Non-empty "device C0": never offered.
        let (colC0, wantsC0) = try makeRepos(sub: "deviceC0")
        try await colC0.addEntry(fixtureEntry(id: "x1", groupId: ""))
        let serviceC0 = makeService(collection: colC0, wants: wantsC0)
        await serviceC0.offerRestoreIfEligible()
        XCTAssertNil(serviceC0.restoreOffer)

        // "device C": offered while empty (captures the 1-entry snapshot), then a first scan
        // lands locally before the user confirms (the race) — accepting downgrades to
        // warn-and-confirm instead of overwriting.
        let (colC, wantsC) = try makeRepos(sub: "deviceC")
        let serviceC = makeService(collection: colC, wants: wantsC)
        await serviceC.offerRestoreIfEligible()
        let offerC = serviceC.restoreOffer!
        try await colC.addEntry(fixtureEntry(id: "c1", groupId: ""))

        // Between the offer and the confirm, device A's debounced auto-backup fires again
        // with more data — the file on disk is no longer what was shown to the user.
        try await colA.addEntry(fixtureEntry(id: "e2", groupId: gid))
        await makeService(collection: colA, wants: wantsA).backUpNow()

        await serviceC.acceptRestore(offerC)
        XCTAssertEqual(serviceC.restoreOffer?.requiresOverwriteConfirmation, true)
        let entriesC = await firstValue(colC.entriesStream()) ?? []
        XCTAssertEqual(entriesC.map(\.id), ["c1"])   // nothing was overwritten yet

        // Second accept (now carrying the confirmation flag) restores the snapshot that was
        // ORIGINALLY OFFERED — not the newer file that landed on disk in the meantime.
        await serviceC.acceptRestore(serviceC.restoreOffer!)
        let replacedC = await firstValue(colC.entriesStream()) ?? []
        XCTAssertEqual(replacedC.map(\.id), ["e1"])   // NOT ["e1", "e2"]
    }

    /// A v1 backup file predates `wantEntries` — the decoded snapshot has it as nil (the field's
    /// default). Restoring must still land the ids, with fresh default `WantEntry` values.
    func testRestoreFallsBackToDefaultsForV1BackupWithoutWantEntries() async throws {
        let (col, wants) = try makeRepos(sub: "deviceV1")
        let service = makeService(collection: col, wants: wants)
        let v1Snapshot = BackupSnapshot(exportedAt: fixedNow, groups: [], entries: [],
                                        wanted: ["a1", "b2"], wantEntries: nil)

        try await service.performRestore(snapshot: v1Snapshot)

        let wanted = await firstValue(wants.stream(uid: "local")) ?? [:]
        XCTAssertEqual(Set(wanted.keys), ["a1", "b2"])
        // WantEntry() stamps `addedAt: Date()` at construction, so compare fields rather than
        // the whole struct (two independently-constructed defaults never compare equal).
        for id in ["a1", "b2"] {
            XCTAssertEqual(wanted[id]?.priority, .normal)
            XCTAssertNil(wanted[id]?.targetUsd)
            XCTAssertEqual(wanted[id]?.notes, "")
        }
    }

    /// Goals survive device A → backup file → device B, and the restore replaces (not merges)
    /// whatever the new device happened to be chasing.
    func testSetGoalsRoundTripThroughBackupAndRestore() async throws {
        let (colA, wantsA) = try makeRepos(sub: "goalsA")
        try await colA.addEntry(fixtureEntry(id: "e1", groupId: ""))
        let goalsA = makeGoals(sub: "goalsA")
        goalsA.toggle("base1")
        goalsA.toggle("sv1")
        await makeService(collection: colA, wants: wantsA, setGoals: goalsA).backUpNow()

        let (colB, wantsB) = try makeRepos(sub: "goalsB")
        let goalsB = makeGoals(sub: "goalsB")
        goalsB.toggle("swsh4")
        let serviceB = makeService(collection: colB, wants: wantsB, setGoals: goalsB)
        try await serviceB.performRestore(snapshot: serviceB.loadBackup())

        XCTAssertEqual(goalsB.setIds, ["base1", "sv1"])
        // Persisted, not just in memory — a relaunch must see the restored goals.
        XCTAssertEqual(SetGoalsModel.load(from: dir.appendingPathComponent("goalsB", isDirectory: true)
            .appendingPathComponent("set-goals.json")), ["base1", "sv1"])
    }

    /// A v2 backup file has no `setGoals` key. It must still decode (as nil), and restoring it
    /// must leave the device's own goals alone rather than wiping them.
    func testV2BackupDecodesAsV3AndLeavesGoalsUntouched() async throws {
        let v2JSON = """
        {"schemaVersion":2,"exportedAt":"2023-11-14T22:13:20Z","groups":[],"entries":[],
         "wanted":["a1"],
         "wantEntries":{"a1":{"priority":1,"notes":"","addedAt":"2023-11-14T22:13:20Z"}}}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(BackupSnapshot.self, from: v2JSON)
        XCTAssertEqual(snapshot.schemaVersion, 2)
        XCTAssertNil(snapshot.setGoals)

        let (col, wants) = try makeRepos(sub: "deviceV2")
        let goals = makeGoals(sub: "deviceV2")
        goals.toggle("base1")
        try await makeService(collection: col, wants: wants, setGoals: goals)
            .performRestore(snapshot: snapshot)

        XCTAssertEqual(goals.setIds, ["base1"])
        let restoredWants = await firstValue(wants.stream(uid: "local")) ?? [:]
        XCTAssertEqual(Set(restoredWants.keys), ["a1"])
    }

    // MARK: Sealed products (schema v4)

    /// A v3 backup file has no `sealed` key. It must still decode (as nil), and restoring it must
    /// leave the device's own sealed products alone rather than wiping them — the same rule
    /// `setGoals` earns, and the reason both are real Optionals.
    func testV3BackupDecodesAndLeavesSealedUntouched() async throws {
        let v3JSON = """
        {"schemaVersion":3,"exportedAt":"2023-11-14T22:13:20Z","groups":[],"entries":[],
         "wanted":[],"setGoals":[]}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(BackupSnapshot.self, from: v3JSON)
        XCTAssertEqual(snapshot.schemaVersion, 3)
        XCTAssertNil(snapshot.sealed)

        let (col, wants) = try makeRepos(sub: "deviceV3")
        try await col.addSealed(SealedEntry(id: "mine", productId: 517_898, qty: 2,
                                            pricePaid: 900, addedAt: fixedNow))
        try await makeService(collection: col, wants: wants).performRestore(snapshot: snapshot)

        let sealed = await firstValue(col.sealedStream()) ?? []
        XCTAssertEqual(sealed.map(\.id), ["mine"], "a v3 backup says nothing about sealed")
        XCTAssertEqual(sealed.first?.pricePaid, 900)
    }

    /// A v4 backup carries sealed, and restoring it replaces what's on the device — last writer
    /// wins, exactly as it does for cards.
    func testV4BackupCapturesAndRestoresSealed() async throws {
        let (colA, wantsA) = try makeRepos(sub: "sealedA")
        try await colA.addSealed(SealedEntry(id: "s1", productId: 517_898, qty: 3, pricePaid: 1350,
                                             acquiredFrom: "card show", addedAt: fixedNow))
        await makeService(collection: colA, wants: wantsA).backUpNow()

        let written = try await makeService(collection: colA, wants: wantsA).loadBackup()
        XCTAssertEqual(written.schemaVersion, 4)
        XCTAssertEqual(written.sealed?.map(\.id), ["s1"])

        let (colB, wantsB) = try makeRepos(sub: "sealedB")
        try await colB.addSealed(SealedEntry(id: "replaced", productId: 1, qty: 1, addedAt: fixedNow))
        try await makeService(collection: colB, wants: wantsB).performRestore(snapshot: written)

        let restored = await firstValue(colB.sealedStream()) ?? []
        XCTAssertEqual(restored.map(\.id), ["s1"])
        XCTAssertEqual(restored.first?.qty, 3)
        XCTAssertEqual(restored.first?.pricePaid, 1350)
        XCTAssertEqual(restored.first?.acquiredFrom, "card show")
    }

    /// Chasing a set is a backup-worthy change on its own — it must arm the debounce even when
    /// the collection and wishlist never move.
    func testGoalChangeAloneTriggersBackup() async throws {
        let (col, wants) = try makeRepos(sub: "goalTrigger")
        try await col.addEntry(fixtureEntry(id: "e1", groupId: ""))
        let goals = makeGoals(sub: "goalTrigger")
        let service = makeService(collection: col, wants: wants, setGoals: goals,
                                  debounce: .milliseconds(50))
        service.start()

        goals.toggle("base1")
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(service.status, .backedUp(fixedNow))
        let written = try await service.loadBackup()
        XCTAssertEqual(written.setGoals, ["base1"])
    }

    func testAutoBackupDebouncesAndSkipsInitialEmissions() async throws {
        let (col, wants) = try makeRepos(sub: "deviceA")
        try await col.addEntry(fixtureEntry(id: "e1", groupId: ""))   // pre-existing data

        let service = makeService(collection: col, wants: wants, debounce: .milliseconds(50))
        service.start()

        // The streams' initial emissions alone must never write — a fresh launch would
        // otherwise clobber a real backup with an empty snapshot before the restore prompt runs.
        try await Task.sleep(for: .milliseconds(300))
        let file = dir.appendingPathComponent("icloud", isDirectory: true)
            .appendingPathComponent(BackupService.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // A mutation arms the debounce; the snapshot lands after it fires.
        try await Task.sleep(for: .milliseconds(50))   // let subscriptions settle past "first"
        try await col.addEntry(fixtureEntry(id: "e2", groupId: ""))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let snapshot = try await service.loadBackup()
        XCTAssertEqual(Set(snapshot.entries.map(\.id)), ["e1", "e2"])
    }
}
