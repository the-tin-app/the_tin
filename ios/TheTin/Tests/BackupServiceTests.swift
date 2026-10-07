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
                             setGoals: SetGoalsModel? = nil, binders: BinderLayoutsModel? = nil,
                             debounce: Duration = .seconds(5)) -> BackupService {
        // A per-service defaults suite: `.standard` is shared by every test in the process (and
        // survives the run), so the last-written fingerprint would leak between cases.
        BackupService(store: TempDirBackupStore(dir: dir.appendingPathComponent("icloud", isDirectory: true)),
                      collection: collection, wants: wants, setGoals: setGoals, binders: binders,
                      uid: "local",
                      defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                      debounce: debounce, now: { self.fixedNow })
    }

    /// A goals model persisting under `<dir>/<sub>/set-goals.json`.
    private func makeGoals(sub: String) -> SetGoalsModel {
        SetGoalsModel(paths: SetGoalPaths(fileURL: dir.appendingPathComponent(sub, isDirectory: true)
            .appendingPathComponent("set-goals.json")))
    }

    /// A binders model persisting under `<dir>/<sub>/binders.json`.
    private func makeBinders(sub: String) -> BinderLayoutsModel {
        BinderLayoutsModel(paths: BinderPaths(fileURL: dir.appendingPathComponent(sub, isDirectory: true)
            .appendingPathComponent("binders.json")))
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
        XCTAssertEqual(snapshot.schemaVersion, 5)
        XCTAssertEqual(snapshot.setGoals, ["base1"])
        XCTAssertEqual(snapshot.exportedAt, fixedNow)
        XCTAssertEqual(snapshot.groups.map(\.id), [gid])
        XCTAssertEqual(snapshot.entries, [entry])   // full Codable round-trip, field by field
        XCTAssertEqual(snapshot.wanted, ["sv1-25"])
        XCTAssertNotNil(snapshot.wantEntries?["sv1-25"])

        // Two-slot rotation: a second write moves the previous snapshot to the .prev slot.
        // It has to be a write of something NEW — an unchanged snapshot is skipped now.
        try await col.addEntry(fixtureEntry(id: "e2", groupId: gid))
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

    /// Binder layouts survive device A → backup file → device B, and the restore replaces
    /// (not merges) whatever the new device had laid out.
    func testBindersRoundTripThroughBackupAndRestore() async throws {
        let (colA, wantsA) = try makeRepos(sub: "bindersA")
        try await colA.addEntry(fixtureEntry(id: "e1", groupId: ""))
        // A real divider, because a restore now prunes layouts whose divider the backup lacks.
        let gid = try await colA.createGroup(name: "Binder")
        let bindersA = makeBinders(sub: "bindersA")
        let layout = BinderLayout(groupId: gid, shape: PageShape(rows: 1, cols: 2),
                                  pages: [BinderPage(slots: [PlannedCard(cardId: "a"), nil])])
        bindersA.save(layout)
        await makeService(collection: colA, wants: wantsA, binders: bindersA).backUpNow()

        let (colB, wantsB) = try makeRepos(sub: "bindersB")
        let bindersB = makeBinders(sub: "bindersB")
        bindersB.save(BinderLayout(groupId: "other"))
        let serviceB = makeService(collection: colB, wants: wantsB, binders: bindersB)
        try await serviceB.performRestore(snapshot: serviceB.loadBackup())

        XCTAssertEqual(bindersB.all, [layout])
        // Persisted, not just in memory — a relaunch must see the restored layout.
        let bindersPath = dir.appendingPathComponent("bindersB", isDirectory: true)
            .appendingPathComponent("binders.json")
        XCTAssertEqual(BinderLayoutsModel(paths: BinderPaths(fileURL: bindersPath)).all, [layout])
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

    /// A backup carries sealed, and restoring it replaces what's on the device — last writer
    /// wins, exactly as it does for cards. (Was `testV4BackupCapturesAndRestoresSealed`; renamed
    /// when `schemaVersion` moved to 5 — this asserts the version a fresh write CARRIES, not that
    /// an old file decodes, so "V4" in the name was never accurate to what it checks.)
    func testABackupCapturesAndRestoresSealed() async throws {
        let (colA, wantsA) = try makeRepos(sub: "sealedA")
        try await colA.addSealed(SealedEntry(id: "s1", productId: 517_898, qty: 3, pricePaid: 1350,
                                             acquiredFrom: "card show", addedAt: fixedNow))
        await makeService(collection: colA, wants: wantsA).backUpNow()

        let written = try await makeService(collection: colA, wants: wantsA).loadBackup()
        XCTAssertEqual(written.schemaVersion, 5)
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

    /// Laying out a binder is a backup-worthy change on its own — it must arm the debounce even
    /// when the collection and wishlist never move. Mirrors `testGoalChangeAloneTriggersBackup`,
    /// including its debounce-vs-sleep timing (see that test's sibling flakiness note).
    func testBinderChangeAloneTriggersBackup() async throws {
        let (col, wants) = try makeRepos(sub: "binderTrigger")
        try await col.addEntry(fixtureEntry(id: "e1", groupId: ""))
        let binders = makeBinders(sub: "binderTrigger")
        let service = makeService(collection: col, wants: wants, binders: binders,
                                  debounce: .milliseconds(50))
        service.start()

        binders.save(BinderLayout(groupId: "g1"))
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(service.status, .backedUp(fixedNow))
        let written = try await service.loadBackup()
        XCTAssertEqual(written.binders?.map(\.groupId), ["g1"])
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

    // MARK: Two devices, one file

    /// A second device with its own UserDefaults and its own clock — the whole point of the
    /// injection is that these are two devices, not one talking to itself.
    private func makeDevice(sub: String, at date: Date) throws
    -> (BackupService, LocalCollectionRepository) {
        let (collection, wants) = try makeRepos(sub: sub)
        let service = BackupService(
            store: TempDirBackupStore(dir: dir.appendingPathComponent("icloud", isDirectory: true)),
            collection: collection, wants: wants, uid: "local",
            defaults: UserDefaults(suiteName: "test-\(sub)-\(UUID().uuidString)")!,
            debounce: .seconds(5), now: { date })
        return (service, collection)
    }

    /// The bug, exactly: an idle second device overwrote the phone's newer backup with its own
    /// staler collection and nothing warned (device pair, 2026-08-10).
    func testAStalerDeviceRefusesToOverwriteANewerBackup() async throws {
        let (phone, phoneCollection) = try makeDevice(sub: "phone", at: fixedNow)
        try await phoneCollection.addEntry(fixtureEntry(id: "e1", groupId: ""))
        await phone.backUpNow()

        let (pad, _) = try makeDevice(sub: "pad", at: fixedNow.addingTimeInterval(60))
        await pad.backUpNow()   // the iPad is empty and would have clobbered the phone

        XCTAssertEqual(pad.conflict?.entryCount, 1)
        let onDisk = try await pad.loadBackup()
        XCTAssertEqual(onDisk.entries.map(\.id), ["e1"], "the phone's backup must survive")
    }

    /// Taking the other device's backup makes it ours — otherwise the device would refuse to
    /// back up forever, calling the snapshot it is now running on foreign.
    func testAcceptingTheConflictRestoresAndThenBacksUpNormally() async throws {
        let (phone, phoneCollection) = try makeDevice(sub: "phone", at: fixedNow)
        try await phoneCollection.addEntry(fixtureEntry(id: "e1", groupId: ""))
        await phone.backUpNow()

        let (pad, padCollection) = try makeDevice(sub: "pad", at: fixedNow.addingTimeInterval(60))
        await pad.backUpNow()
        try await pad.acceptConflict()

        XCTAssertNil(pad.conflict)
        let restored = await firstValue(padCollection.entriesStream()) ?? []
        XCTAssertEqual(restored.map(\.id), ["e1"])

        try await padCollection.addEntry(fixtureEntry(id: "e2", groupId: ""))
        await pad.backUpNow()
        XCTAssertNil(pad.conflict, "the backup it restored from is its own now")
        let onDisk = try await pad.loadBackup()
        XCTAssertEqual(Set(onDisk.entries.map(\.id)), ["e1", "e2"])
    }

    /// The escape hatch: this device's data is the one you want, so overwrite deliberately.
    func testOverwritingTheConflictKeepsThisDevicesData() async throws {
        let (phone, phoneCollection) = try makeDevice(sub: "phone", at: fixedNow)
        try await phoneCollection.addEntry(fixtureEntry(id: "e1", groupId: ""))
        await phone.backUpNow()

        let (pad, padCollection) = try makeDevice(sub: "pad", at: fixedNow.addingTimeInterval(60))
        try await padCollection.addEntry(fixtureEntry(id: "e2", groupId: ""))
        await pad.backUpNow()
        XCTAssertNotNil(pad.conflict)

        await pad.overwriteConflict()

        XCTAssertNil(pad.conflict)
        let onDisk = try await pad.loadBackup()
        XCTAssertEqual(onDisk.entries.map(\.id), ["e2"])
    }

    /// The phantom write: a launch that changed nothing produced a fresh `exportedAt` over
    /// identical data, which kept the idle iPad permanently "newest" and meant it could never
    /// fall behind — so the conflict guard could never fire on it (device pair, 2026-08-10).
    func testAnUnchangedSnapshotIsNotWrittenAgain() async throws {
        let (phone, collection) = try makeDevice(sub: "phone", at: fixedNow)
        try await collection.addEntry(fixtureEntry(id: "e1", groupId: ""))
        await phone.backUpNow()

        let file = dir.appendingPathComponent("icloud", isDirectory: true)
            .appendingPathComponent(BackupService.fileName)
        let first = try Data(contentsOf: file)

        await phone.backUpNow()   // nothing changed in between

        let prev = dir.appendingPathComponent("icloud", isDirectory: true)
            .appendingPathComponent(BackupService.prevFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prev.path),
                       "a skipped write must not rotate the previous slot away")
        XCTAssertEqual(try Data(contentsOf: file), first)
    }

    /// …but a real change still writes.
    func testAChangedSnapshotIsWritten() async throws {
        let (phone, collection) = try makeDevice(sub: "phone", at: fixedNow)
        try await collection.addEntry(fixtureEntry(id: "e1", groupId: ""))
        await phone.backUpNow()

        try await collection.addEntry(fixtureEntry(id: "e2", groupId: ""))
        await phone.backUpNow()

        let onDisk = try await phone.loadBackup()
        XCTAssertEqual(Set(onDisk.entries.map(\.id)), ["e1", "e2"])
    }

    /// One device, many launches: writing its own backup repeatedly must never look foreign.
    func testASingleDeviceNeverConflictsWithItself() async throws {
        let (phone, collection) = try makeDevice(sub: "phone", at: fixedNow)
        try await collection.addEntry(fixtureEntry(id: "e1", groupId: ""))
        await phone.backUpNow()
        XCTAssertNil(phone.conflict)

        try await collection.addEntry(fixtureEntry(id: "e2", groupId: ""))
        await phone.backUpNow()

        XCTAssertNil(phone.conflict)
        let onDisk = try await phone.loadBackup()
        XCTAssertEqual(Set(onDisk.entries.map(\.id)), ["e1", "e2"])
    }

    /// A v4 backup has no `binders` key. It must still decode (as nil) — the actual "leaves local
    /// binders untouched" claim is proved by `testAPreV5BackupLeavesBindersOnDiskUntouched` below,
    /// which runs this JSON through a real restore; this test only checks the decode.
    func testAPreV5BackupDecodesWithNoBindersAndClearsNothing() throws {
        let json = #"{"schemaVersion":4,"exportedAt":0,"groups":[],"entries":[],"wanted":[]}"#
        let snapshot = try JSONDecoder().decode(BackupSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.binders)
    }

    /// A v4 backup says NOTHING about binders. Restoring one through the real `BackupService`
    /// must leave the device's own binder layouts alone rather than wiping them — the same rule
    /// `setGoals` and `sealed` each earn, and what makes the test above's name honest.
    func testAPreV5BackupLeavesBindersOnDiskUntouched() async throws {
        // The divider IS in the backup: a layout whose divider is not is a separate rule, pinned
        // by `testARestoreDropsALayoutWhoseDividerIsGone`.
        let json = #"{"schemaVersion":4,"exportedAt":0,"groups":[{"id":"g1","name":"Binder","sortOrder":0,"createdAt":0}],"entries":[],"wanted":[]}"#
        let snapshot = try JSONDecoder().decode(BackupSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.binders)

        let (col, wants) = try makeRepos(sub: "deviceV4Binders")
        let binders = makeBinders(sub: "deviceV4Binders")
        let layout = BinderLayout(groupId: "g1")
        binders.save(layout)
        try await makeService(collection: col, wants: wants, binders: binders)
            .performRestore(snapshot: snapshot)

        XCTAssertEqual(binders.all, [layout], "a v4 backup says nothing about binders")
    }

    /// A restore replaces the dividers wholesale, so a layout keyed to one the backup does not
    /// have is orphaned — invisible forever, and copied into every later backup. Both branches
    /// prune: a v5 backup can carry a stale layout too.
    func testARestoreDropsALayoutWhoseDividerIsGone() async throws {
        let (col, wants) = try makeRepos(sub: "orphanBinders")
        let binders = makeBinders(sub: "orphanBinders")
        let kept = BinderLayout(groupId: "g1")
        binders.save(kept)
        binders.save(BinderLayout(groupId: "gone"))
        let group = CardGroup(id: "g1", name: "Binder", sortOrder: 0, createdAt: fixedNow)
        let service = makeService(collection: col, wants: wants, binders: binders)

        try await service.performRestore(
            snapshot: BackupSnapshot(exportedAt: fixedNow, groups: [group], entries: [], wanted: []))
        XCTAssertEqual(binders.all, [kept], "a v4 backup keeps local layouts, minus the orphan")

        try await service.performRestore(
            snapshot: BackupSnapshot(exportedAt: fixedNow, groups: [group], entries: [], wanted: [],
                                     binders: [kept, BinderLayout(groupId: "stale")]))
        XCTAssertEqual(binders.all, [kept], "and the snapshot's own list is pruned the same way")
    }

    func testABinderLayoutRoundTripsThroughASnapshot() throws {
        let layout = BinderLayout(groupId: "g1", shape: PageShape(rows: 1, cols: 2),
                                  pages: [BinderPage(slots: [PlannedCard(cardId: "a"), nil])])
        let snapshot = BackupSnapshot(exportedAt: Date(), groups: [], entries: [], wanted: [],
                                      binders: [layout])
        let decoded = try JSONDecoder().decode(
            BackupSnapshot.self, from: try JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.binders, [layout])
        XCTAssertEqual(decoded.schemaVersion, 5)
    }
}
