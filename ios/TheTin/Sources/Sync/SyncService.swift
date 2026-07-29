import Foundation
import Observation

/// The first-run question, when two devices already hold different collections. Real counts, not
/// adjectives — "2,847 cards" is something you can recognise; "your other device" is not.
struct SeedPrompt: Equatable {
    var localCount: Int
    var remoteCount: Int
}

/// Multi-device sync, layered over the existing repositories as a SECOND WRITER.
///
/// `LocalCollectionRepository` stays authoritative and unchanged as the read path, so offline and
/// signed-out behave exactly as today. Sync is not a new database: it subscribes to the streams
/// the repositories already publish, diffs each emission into records, and hands the delta to the
/// engine. **Zero lines change in `LocalCollectionRepository`, `LocalWantsRepository` or
/// `SetGoalsModel`.**
///
/// Failures never crash and never block a write — same degrade philosophy as the repositories.
/// Without an engine (no account, toggle off, or the CloudKit entitlement not yet applied) it
/// reports `.unavailable`, subscribes to nothing, and the app is byte-for-byte what it is today.
@MainActor @Observable
final class SyncService {
    private(set) var status: SyncStatus = .unavailable
    /// Observable mirror of `AppConfig.syncEnabled` — UserDefaults isn't observable, so a Settings
    /// toggle bound straight to it wouldn't redraw.
    private(set) var isEnabled = AppConfig.syncEnabled
    /// Non-nil while the first-run "which device wins?" sheet should be up. `RootView` presents it.
    var seedPrompt: SeedPrompt?

    static let seededKey = "syncSeeded"

    private let engine: SyncEngine?
    private let collection: CollectionRepository
    private let wants: WantsRepository
    private let setGoals: SetGoalsModel?
    /// The file-shaped undo for the one destructive moment. Optional so tests and catalog-only
    /// wiring construct the service unchanged.
    private let backup: BackupService?
    private let uid: String
    private let defaults: UserDefaults

    /// One content-hash map per record type. Scoped per type because each stream only ever
    /// carries one — diffing a whole-collection map against an entries-only emission would read
    /// as "every group was deleted".
    private var hashes: [SyncRecordType: [String: Int]] = [:]
    private var streamTasks: [Task<Void, Never>] = []
    private var goalsHookInstalled = false
    /// Held between presenting the seed prompt and the user answering it.
    private var pendingRemote: [SyncRecord] = []

    init(engine: SyncEngine? = SyncService.makeEngine(),
         collection: CollectionRepository, wants: WantsRepository,
         setGoals: SetGoalsModel? = nil, backup: BackupService? = nil,
         uid: String, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.collection = collection
        self.wants = wants
        self.setGoals = setGoals
        self.backup = backup
        self.uid = uid
        self.defaults = defaults
    }

    /// The production engine, or nil when CloudKit isn't wired up yet.
    ///
    /// `TIN_CLOUDKIT` is defined by the same change that applies the CloudKit entitlement.
    /// `CloudKitSyncEngine` still COMPILES either way (so the compiler checks it) — it just isn't
    /// constructed, because `CKContainer(identifier:)` traps for a container the app isn't
    /// entitled to. A nil engine is the same code path as "signed out".
    nonisolated static func makeEngine() -> SyncEngine? {
        #if TIN_CLOUDKIT
        return CloudKitSyncEngine()
        #else
        return nil
        #endif
    }

    // MARK: Lifecycle

    func start() async {
        guard AppConfig.syncEnabled, let engine, streamTasks.isEmpty, seedPrompt == nil else {
            if engine == nil || !AppConfig.syncEnabled { status = .unavailable }
            return
        }
        engine.onStatus = { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
        do { try await engine.start() } catch { status = .unavailable; return }
        status = .syncing

        // An empty list must NOT stand in for an unreadable zone. `try?` conflated them, and the
        // seeding table below reads `remoteCount == 0` as "the zone is empty, seed it from here"
        // — so one transient CloudKit error on first run would mark the device seeded and skip
        // the "which device wins?" sheet permanently. On an already-seeded device the same
        // conflation reported a catch-up that applied nothing as `.synced`. Both are silent.
        //
        // Nothing is subscribed on this path, so `refresh()` retries `start()` on the next
        // foreground rather than leaving sync inert until the user relaunches.
        let remote: [SyncRecord]
        do { remote = try await engine.fetchAll() } catch { status = .failed; return }
        let local = await currentRecords()
        switch SyncSeeding.decide(localCount: local.filter { $0.type == .entry }.count,
                                  remoteCount: remote.filter { $0.type == .entry }.count,
                                  alreadySeeded: defaults.bool(forKey: Self.seededKey)) {
        case .seedZone:
            engine.send(upserts: local, deletes: [])
            markSeeded()
        case .pullDown:
            await applyRemote(upserts: remote, deletes: [])
            markSeeded()
        case .ask(let localCount, let remoteCount):
            // Subscribe to NOTHING until the user answers: a local edit pushed before the choice
            // would silently merge the two collections the sheet is asking them to pick between.
            pendingRemote = remote
            seedPrompt = SeedPrompt(localCount: localCount, remoteCount: remoteCount)
            return
        case .none:
            // Already seeded — but the records just fetched must still be applied, not dropped.
            // `automaticallySync` only reacts to LOCAL pending changes and to push; a device with
            // neither never fetches on its own, so without this a card added elsewhere never
            // arrives, even across relaunches. Upserts only: a record missing from the zone is not
            // evidence of a delete here, and treating it as one would erase anything this device
            // has queued but not yet sent. Observed on device 2026-07-29.
            await applyRemote(upserts: remote, deletes: [])
        }
        subscribe()
        // `fetchAll` above carries upserts only, so a cold launch alone can never learn about a
        // DELETE made elsewhere. `.onChange(of: scenePhase)` does not fire for the INITIAL
        // `.active` either, so `refresh()` doesn't cover a cold launch — without this line a
        // record deleted on another device survives until the app is backgrounded and
        // foregrounded again. Confirmed on device 2026-07-29.
        await engine.fetchChanges()
    }

    /// Catch up now — called when the app comes to the foreground.
    ///
    /// `CKSyncEngine` fetches on its own only for push and for local pending changes, so a device
    /// that has merely been sitting there never learns what the other one did. `start()` covers a
    /// cold launch; this covers every foreground after it, which is the common case (iOS suspends
    /// rather than terminates).
    ///
    /// Goes through the change feed rather than repeating `start()`'s `fetchAll`, because that is
    /// the only path that carries **deletions** — see `SyncEngine.fetchChanges`.
    ///
    /// No-op before seeding: `streamTasks.isEmpty` means `start()` hasn't finished or the seed
    /// sheet is still up, and pulling the zone into a device whose choice hasn't been made would
    /// merge the two collections the sheet is asking the user to pick between.
    func refresh() async {
        guard AppConfig.syncEnabled, let engine, seedPrompt == nil else { return }
        // Nothing subscribed means `start()` never got past the zone read (or hasn't run). A
        // foreground is the natural moment to try again — otherwise one failed read at launch
        // leaves sync dead for the whole session and only a relaunch revives it.
        guard !streamTasks.isEmpty else { return await start() }
        await engine.fetchChanges()
    }

    /// The seed sheet's answer. `useLocal` = "this device's tin is the real one".
    func resolveSeed(useLocal: Bool) async {
        guard let engine, seedPrompt != nil else { return }
        seedPrompt = nil
        // The destructive choice gets a file-shaped undo that predates it, so a mis-tap costs a
        // trip to Settings → Restore rather than the collection.
        await backup?.backUpNow()
        let remote = pendingRemote
        pendingRemote = []
        if useLocal {
            let local = await currentRecords()
            let keep = Set(local.map(\.key))
            engine.send(upserts: local, deletes: remote.filter { !keep.contains($0.key) })
        } else {
            let local = await currentRecords()
            let keep = Set(remote.map(\.key))
            await applyRemote(upserts: remote,
                              deletes: local.filter { !keep.contains($0.key) })
        }
        markSeeded()
        subscribe()
    }

    /// "Not Now" on the seed sheet. Neither choice is safe to guess, so declining leaves sync
    /// inert for the session; the flag stays unset and the question comes back next launch.
    func declineSeed() {
        seedPrompt = nil
        pendingRemote = []
        stop()
        status = .unavailable
    }

    /// Settings toggle. Off stops the engine; local keeps working exactly as before.
    func setEnabled(_ enabled: Bool) async {
        AppConfig.syncEnabled = enabled
        isEnabled = enabled
        if enabled {
            await start()
        } else {
            stop()
            status = .unavailable
        }
    }

    func stop() {
        streamTasks.forEach { $0.cancel() }
        streamTasks = []
        hashes = [:]
        engine?.stop()
    }

    private func markSeeded() { defaults.set(true, forKey: Self.seededKey) }

    // MARK: Outbound — diff the streams the repositories already publish

    private func subscribe() {
        guard streamTasks.isEmpty else { return }
        // Attached HERE, not in `start()`: while the seed sheet is up nothing may cross in either
        // direction, or a record arriving mid-question would merge the two collections the user is
        // being asked to choose between.
        engine?.onRemoteChange = { [weak self] upserts, deletes in
            Task { @MainActor in await self?.applyRemote(upserts: upserts, deletes: deletes) }
        }
        streamTasks.append(Task { [weak self] in
            guard let stream = self?.collection.groupsStream() else { return }
            var first = true
            for await groups in stream {
                await self?.push(.group, groups.compactMap { try? SyncRecord.group($0) },
                                 seedOnly: first)
                first = false
            }
        })
        streamTasks.append(Task { [weak self] in
            guard let stream = self?.collection.entriesStream() else { return }
            var first = true
            for await entries in stream {
                await self?.push(.entry, entries.compactMap { try? SyncRecord.entry($0) },
                                 seedOnly: first)
                first = false
            }
        })
        streamTasks.append(Task { [weak self, uid = self.uid] in
            guard let stream = self?.wants.stream(uid: uid) else { return }
            var first = true
            for await map in stream {
                await self?.push(.want, map.compactMap { try? SyncRecord.want(cardId: $0.key, $0.value) },
                                 seedOnly: first)
                first = false
            }
        })
        installGoalsHook()
    }

    /// Goals have no stream (one small file, written whole) so the model calls back instead —
    /// the same arrangement `BackupService` uses. That callback is a single closure and backup
    /// already owns it, so chain rather than replace: dropping backup's would silently stop
    /// backing up chased sets.
    private func installGoalsHook() {
        guard !goalsHookInstalled, let setGoals else { return }
        goalsHookInstalled = true
        let previous = setGoals.onChange
        setGoals.onChange = { [weak self] in
            previous?()
            Task { @MainActor in await self?.pushGoals(seedOnly: false) }
        }
        Task { await pushGoals(seedOnly: true) }
    }

    private func pushGoals(seedOnly: Bool) async {
        await push(.setGoal, (setGoals?.setIds ?? []).sorted().map(SyncRecord.setGoal),
                   seedOnly: seedOnly)
    }

    /// A stream emission became records; diff them and queue whatever moved.
    ///
    /// `seedOnly` covers each stream's first emission (its current value on subscribe): fold it
    /// into the map without pushing. A change made in a previous session isn't lost by that —
    /// `CKSyncEngine` persists its own pending-change state across launches, which is why an
    /// offline delete needs no tombstone in `collection.json`.
    private func push(_ type: SyncRecordType, _ records: [SyncRecord], seedOnly: Bool) async {
        // `isEnabled` is re-checked here, not just at subscribe time: cancelling a stream task is
        // asynchronous, so one more emission can land after the toggle went off — and it would
        // diff against the map `stop()` just cleared, i.e. push the whole collection.
        guard isEnabled else { return }
        let changes = SyncDiff.changes(previous: hashes[type] ?? [:], current: records)
        hashes[type] = changes.hashes
        guard !seedOnly, !changes.isEmpty, let engine else { return }
        engine.send(upserts: changes.upserts,
                    deletes: changes.deletes.map {
                        SyncRecord(type: type, recordName: $0, payload: nil)
                    })
        status = .syncing
    }

    // MARK: Inbound

    /// Write records that came from another device into the local repositories.
    ///
    /// The hash maps are updated BEFORE the write. Writing notifies, which diffs, which would push
    /// the record straight back — folding it in at apply time makes that notify find no delta, and
    /// the loop dies on the first pass.
    ///
    /// A write that FAILS must undo that fold. `LocalCollectionRepository.mutate` rolls back and
    /// throws before `notify()` precisely so nothing observes state that isn't on disk; swallowing
    /// the error here would leave the map claiming local matches remote when it doesn't, and the
    /// record would never be re-applied — a card silently eaten. So the pre-fold map is kept and
    /// restored per failed write, and `.synced` is only claimed when every attempted write landed.
    private func applyRemote(upserts: [SyncRecord], deletes: [SyncRecord]) async {
        let beforeApply = hashes
        for type in SyncRecordType.allCases {
            var map = hashes[type] ?? [:]
            SyncDiff.apply(upserts: upserts.filter { $0.type == type },
                           deletes: deletes.filter { $0.type == type }.map(\.recordName),
                           to: &map)
            hashes[type] = map
        }

        var groups = await first(collection.groupsStream()) ?? []
        var entries = await first(collection.entriesStream()) ?? []
        var wantMap = await first(wants.stream(uid: uid)) ?? [:]
        var goals = setGoals?.setIds ?? []
        var touchedCollection = false, touchedWants = false, touchedGoals = false

        for record in upserts {
            switch record.type {
            case .group:
                guard let group = try? record.decode(CardGroup.self) else { continue }
                if let i = groups.firstIndex(where: { $0.id == group.id }) { groups[i] = group }
                else { groups.append(group) }
                touchedCollection = true
            case .entry:
                guard let entry = try? record.decode(CollectionEntry.self) else { continue }
                if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = entry }
                else { entries.append(entry) }
                touchedCollection = true
            case .want:
                guard let want = try? record.decode(WantEntry.self) else { continue }
                wantMap[record.recordName] = want
                touchedWants = true
            case .setGoal:
                goals.insert(record.recordName)
                touchedGoals = true
            case .sealed:
                continue   // storage arrives with the sealed-ownership branch
            }
        }
        for record in deletes {
            switch record.type {
            case .group:
                groups.removeAll { $0.id == record.recordName }
                touchedCollection = true
            case .entry:
                entries.removeAll { $0.id == record.recordName }
                touchedCollection = true
            case .want:
                if wantMap.removeValue(forKey: record.recordName) != nil { touchedWants = true }
            case .setGoal:
                if goals.remove(record.recordName) != nil { touchedGoals = true }
            case .sealed:
                continue
            }
        }

        // Deliberately whole-set writes: these are the only APIs the repositories expose that
        // preserve ids, and preserving ids is what makes per-record merge work at all. A whole-set
        // write fails wholesale, so restoring the type's whole map is exactly the right granularity.
        var failed = false
        func rollBack(_ types: [SyncRecordType]) {
            for type in types { hashes[type] = beforeApply[type] }
            failed = true
        }
        if touchedCollection {
            do { try await collection.replaceAll(groups: groups, entries: entries) }
            catch { rollBack([.group, .entry]) }
        }
        if touchedWants {
            do { try await wants.save(uid: uid, entries: wantMap) }
            catch { rollBack([.want]) }
        }
        if touchedGoals {
            // `SetGoalsModel.replaceAll` reverts internally instead of throwing, so its outcome
            // has to be read back rather than caught.
            setGoals?.replaceAll(goals)
            if setGoals?.setIds != goals { rollBack([.setGoal]) }
        }
        status = failed ? .failed : .synced(Date())
    }

    // MARK: Reading current state

    /// Every local record, in one shot. Each repository stream yields its current value on
    /// subscribe, so this is race-free — the same trick `BackupService.currentSnapshot` uses.
    private func currentRecords() async -> [SyncRecord] {
        let groups = await first(collection.groupsStream()) ?? []
        let entries = await first(collection.entriesStream()) ?? []
        let wantMap = await first(wants.stream(uid: uid)) ?? [:]
        return groups.compactMap { try? SyncRecord.group($0) }
            + entries.compactMap { try? SyncRecord.entry($0) }
            + wantMap.compactMap { try? SyncRecord.want(cardId: $0.key, $0.value) }
            + (setGoals?.setIds ?? []).sorted().map(SyncRecord.setGoal)
    }

    private func first<T>(_ stream: AsyncStream<T>) async -> T? {
        for await value in stream { return value }
        return nil
    }

}
