import Foundation
import Observation

/// One backup file's contents: the whole owned collection + wishlist, reusing the models'
/// existing Codable conformances verbatim. `schemaVersion` gates future migrations.
struct BackupSnapshot: Codable, Equatable {
    var schemaVersion: Int = 4
    var exportedAt: Date
    var groups: [CardGroup]
    var entries: [CollectionEntry]
    var wanted: [String]
    /// v2: the full per-card wishlist data. Optional + defaulted so a v1 backup (no such key)
    /// still decodes, with this nil — `performRestore` falls back to `wanted`-only defaults.
    var wantEntries: [String: WantEntry]? = nil
    /// v3: the sets you're collecting. Optional + defaulted for the same reason — a v2 backup
    /// decodes with this nil, and `performRestore` then leaves local goals alone rather than
    /// clearing them from a file that never knew about them.
    var setGoals: [String]? = nil
    /// v4: the sealed products you own. Optional + defaulted for the same reason as the two above
    /// — a v3 backup decodes with this nil, and `performRestore` then leaves local sealed alone
    /// rather than clearing it from a file that never knew about it.
    var sealed: [SealedEntry]? = nil
}

/// Why a backup read failed. Manual restore surfaces these; auto-restore treats all as absent.
enum BackupError: LocalizedError {
    case unavailable   // iCloud off / signed out
    case missing       // no backup file in the container
    case undecodable   // file exists but isn't a readable snapshot

    var errorDescription: String? {
        switch self {
        case .unavailable: return "iCloud is unavailable. Check that you're signed in and iCloud Drive is on."
        case .missing: return "No iCloud backup was found."
        case .undecodable: return "The iCloud backup couldn't be read."
        }
    }
}

/// Seam over the iCloud ubiquity container + NSFileCoordinator so backup logic is testable
/// without iCloud (tests inject a plain-FileManager store over a temp dir).
protocol BackupStore: Sendable {
    /// Directory backups live in, or nil when iCloud is off/unavailable. May block while
    /// resolving the ubiquity container — callers must stay off the main thread.
    func containerURL() -> URL?
    func read(_ url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    /// Best-effort move of the current backup into the `.prev` slot (two-slot rotation, so one
    /// corrupted write never destroys the only backup).
    func rotate(_ url: URL, to prev: URL)
    /// Kick off materializing a not-yet-local ubiquitous file. No-op outside iCloud.
    func requestDownload(_ url: URL)
}

// ISO-8601 dates so the backup file is human-inspectable (matches the spec's sample).
private func backupEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}

private func backupDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}

/// Backs up the owned collection + wishlist to iCloud Drive and restores from it: one snapshot
/// file, last writer wins, two-slot rotation. All iCloud IO goes through the injected
/// `BackupStore` and runs off-main (container resolution and coordinated reads can block).
/// Failures never crash — they only surface as `status` (same degrade philosophy as the
/// repositories).
///
/// **Demoted to Settings-only** now that `SyncService` converges devices continuously. The launch
/// restore *offer* is gone: with sync running it was redundant, and two competing "restore your
/// collection?" flows at launch is worse than either alone. `Back Up Now` and
/// `Restore from backup…` stay in Settings unchanged — and the backup earns its keep as the
/// file-shaped undo `SyncService` writes before the one destructive moment it has (the seeding
/// choice), so a mis-tap costs a trip to Settings rather than the collection.
@MainActor @Observable
final class BackupService {
    enum Status: Equatable {
        case unknown          // nothing probed or written yet
        case unavailable      // iCloud off / signed out; retried on the next change
        case backedUp(Date)   // last successful snapshot write (or the on-disk backup's date)
        case failed           // last write threw; retried on the next change
    }

    static let fileName = "backup-v1.json"
    static let prevFileName = "backup-v1.prev.json"

    private(set) var status: Status = .unknown

    private let store: BackupStore
    private let collection: CollectionRepository
    private let wants: WantsRepository
    /// Set goals live in their own model, not a repository (a plain file of ids). Optional so
    /// tests and any goal-less wiring construct the service unchanged.
    private let setGoals: SetGoalsModel?
    private let uid: String
    private let debounce: Duration
    private let now: () -> Date
    private var pendingWrite: Task<Void, Never>?
    private var streamTasks: [Task<Void, Never>] = []

    init(store: BackupStore = ICloudBackupStore(),
         collection: CollectionRepository, wants: WantsRepository,
         setGoals: SetGoalsModel? = nil, uid: String,
         debounce: Duration = .seconds(5), now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.collection = collection
        self.wants = wants
        self.setGoals = setGoals
        self.uid = uid
        self.debounce = debounce
        self.now = now
    }

    // MARK: Auto-backup

    /// Subscribe to the repositories; every mutation re-arms the debounce so the snapshot lands
    /// ~`debounce` after the last write. Each stream's initial emission (current state on
    /// subscribe) is skipped — a fresh install must never clobber a real backup with an empty
    /// snapshot on launch. Idempotent.
    func start() {
        guard streamTasks.isEmpty else { return }
        // Goals have no stream (one small file, written whole), so the model calls back instead.
        // Without this, chasing a set would sit unbacked-up until some other edit happened to fire.
        setGoals?.onChange = { [weak self] in self?.scheduleWrite() }
        streamTasks.append(Task { [weak self] in
            guard let stream = self?.collection.groupsStream() else { return }
            var first = true
            for await _ in stream {
                if first { first = false; continue }
                self?.scheduleWrite()
            }
        })
        streamTasks.append(Task { [weak self] in
            guard let stream = self?.collection.entriesStream() else { return }
            var first = true
            for await _ in stream {
                if first { first = false; continue }
                self?.scheduleWrite()
            }
        })
        streamTasks.append(Task { [weak self, uid = self.uid] in
            guard let stream = self?.wants.stream(uid: uid) else { return }
            var first = true
            for await _ in stream {
                if first { first = false; continue }
                self?.scheduleWrite()
            }
        })
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self, debounce = self.debounce] in
            guard (try? await Task.sleep(for: debounce)) != nil else { return }   // cancelled = superseded
            // Fresh task: backUpNow cancels pendingWrite (= this timer). Running it inline would
            // self-cancel mid-snapshot — a cancelled task's stream reads yield nothing, and the
            // detached write then persists an EMPTY snapshot over real data.
            Task { await self?.backUpNow() }
        }
    }

    // MARK: Backup

    /// Write the snapshot now — the manual "Back Up Now" button and the debounce timer's target.
    func backUpNow() async {
        pendingWrite?.cancel()   // a manual backup supersedes any armed debounce
        guard !Task.isCancelled else { return }   // a cancelled caller must not snapshot empty streams
        let snapshot = await currentSnapshot()
        let store = self.store
        status = await Task.detached { () -> Status in
            guard let dir = store.containerURL() else { return .unavailable }
            do {
                let data = try backupEncoder().encode(snapshot)
                store.rotate(dir.appendingPathComponent(Self.fileName),
                             to: dir.appendingPathComponent(Self.prevFileName))
                try store.write(data, to: dir.appendingPathComponent(Self.fileName))
                return .backedUp(snapshot.exportedAt)
            } catch {
                return .failed
            }
        }.value
    }

    /// Authoritative current state: each repository stream yields its current value on
    /// subscribe, so a one-shot read is race-free (no cached copies to drift).
    private func currentSnapshot() async -> BackupSnapshot {
        var groups: [CardGroup] = []
        var entries: [CollectionEntry] = []
        var wantMap: [String: WantEntry] = [:]
        var sealed: [SealedEntry] = []
        for await v in collection.groupsStream() { groups = v; break }
        for await v in collection.entriesStream() { entries = v; break }
        for await v in collection.sealedStream() { sealed = v; break }
        for await v in wants.stream(uid: uid) { wantMap = v; break }
        return BackupSnapshot(exportedAt: now(), groups: groups, entries: entries,
                              wanted: wantMap.keys.sorted(), wantEntries: wantMap,
                              setGoals: setGoals?.setIds.sorted(), sealed: sealed)
    }

    // MARK: Reading

    /// Read + decode the current backup. A coordinated read of a not-yet-local ubiquitous file
    /// blocks until the download finishes, so `requestDownload` + a plain read is enough.
    func loadBackup() async throws -> BackupSnapshot {
        let store = self.store
        return try await Task.detached { () -> BackupSnapshot in
            guard let dir = store.containerURL() else { throw BackupError.unavailable }
            let url = dir.appendingPathComponent(Self.fileName)
            store.requestDownload(url)
            guard let data = try? store.read(url) else { throw BackupError.missing }
            guard let snapshot = try? backupDecoder().decode(BackupSnapshot.self, from: data) else {
                throw BackupError.undecodable
            }
            return snapshot
        }.value
    }

    /// Settings-open probe: report the on-disk backup's date without writing anything.
    func refreshStatus() async {
        if case .backedUp = status { return }   // an in-session write already set it
        do {
            status = .backedUp(try await loadBackup().exportedAt)
        } catch BackupError.unavailable {
            status = .unavailable
        } catch {
            // missing/undecodable → stay .unknown ("No backup yet" in Settings)
        }
    }

    // MARK: Restore

    /// Replace the local collection + wishlist with `snapshot` (last-writer-wins by design).
    /// Takes the snapshot explicitly — callers restore exactly what the user was shown, not
    /// whatever the file on disk holds now (a debounced auto-backup can swap it in between).
    /// Throws BackupError so the manual Settings path can surface what went wrong.
    func performRestore(snapshot: BackupSnapshot) async throws {
        // nil = a pre-v4 backup, which says nothing about sealed; keep whatever is on the device.
        // `replaceAll` rewrites the whole file, so falling through with an empty array here would
        // silently destroy every sealed product on it — the same trap `setGoals` documents below.
        var sealed = snapshot.sealed
        if sealed == nil {
            for await v in collection.sealedStream() { sealed = v; break }
        }
        try await collection.replaceAll(groups: snapshot.groups, entries: snapshot.entries,
                                        sealed: sealed ?? [])
        let restoredWants = snapshot.wantEntries
            ?? Dictionary(uniqueKeysWithValues: snapshot.wanted.map { ($0, WantEntry()) })
        try await wants.save(uid: uid, entries: restoredWants)
        // nil = a pre-v3 backup, which says nothing about goals; keep whatever is on the device.
        if let ids = snapshot.setGoals { setGoals?.replaceAll(Set(ids)) }
    }
}
