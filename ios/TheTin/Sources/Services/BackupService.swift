import Foundation
import Observation

/// One backup file's contents: the whole owned collection + wishlist, reusing the models'
/// existing Codable conformances verbatim. `schemaVersion` gates future migrations.
struct BackupSnapshot: Codable, Equatable {
    var schemaVersion: Int = 1
    var exportedAt: Date
    var groups: [CardGroup]
    var entries: [CollectionEntry]
    var wanted: [String]
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

/// Backs up the owned collection + wishlist to iCloud Drive and restores from it. Backup-first
/// by design (no live sync): one snapshot file, last writer wins, two-slot rotation. All iCloud
/// IO goes through the injected `BackupStore` and runs off-main (container resolution and
/// coordinated reads can block). Failures never crash — they only surface as `status`
/// (same degrade philosophy as the repositories).
@MainActor @Observable
final class BackupService {
    enum Status: Equatable {
        case unknown          // nothing probed or written yet
        case unavailable      // iCloud off / signed out; retried on the next change
        case backedUp(Date)   // last successful snapshot write (or the on-disk backup's date)
        case failed           // last write threw; retried on the next change
    }

    /// The launch restore prompt's payload. `requiresOverwriteConfirmation` flips when the local
    /// collection stopped being empty between offer and acceptance (first-scan race) — the UI
    /// then re-presents as a warn-and-confirm instead of restoring silently.
    struct RestoreOffer: Equatable {
        var entryCount: Int
        var exportedAt: Date
        var requiresOverwriteConfirmation = false
    }

    static let fileName = "backup-v1.json"
    static let prevFileName = "backup-v1.prev.json"

    private(set) var status: Status = .unknown
    var restoreOffer: RestoreOffer?

    /// The snapshot behind the current/last `restoreOffer`, captured at offer time so
    /// `acceptRestore` restores exactly what the user was shown — never a re-read of the file,
    /// which a debounced auto-backup could have swapped out from under them in the meantime.
    private var offeredSnapshot: BackupSnapshot?

    private let store: BackupStore
    private let collection: CollectionRepository
    private let wants: WantsRepository
    private let uid: String
    private let debounce: Duration
    private let now: () -> Date
    private var pendingWrite: Task<Void, Never>?
    private var streamTasks: [Task<Void, Never>] = []

    init(store: BackupStore = ICloudBackupStore(),
         collection: CollectionRepository, wants: WantsRepository, uid: String,
         debounce: Duration = .seconds(5), now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.collection = collection
        self.wants = wants
        self.uid = uid
        self.debounce = debounce
        self.now = now
    }

    // MARK: Auto-backup

    /// Subscribe to the repositories; every mutation re-arms the debounce so the snapshot lands
    /// ~`debounce` after the last write. Each stream's initial emission (current state on
    /// subscribe) is skipped — a fresh install must never clobber a real backup with an empty
    /// snapshot before the restore prompt runs. Idempotent.
    func start() {
        guard streamTasks.isEmpty else { return }
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

    // MARK: Eligibility (pure)

    /// Auto-restore is offered only to an empty device holding a non-empty backup.
    /// `backupEntryCount` nil = missing or undecodable backup (treated as absent).
    static func restoreEligible(localEntryCount: Int, localWantCount: Int,
                                backupEntryCount: Int?) -> Bool {
        localEntryCount == 0 && localWantCount == 0 && (backupEntryCount ?? 0) > 0
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
        var wanted: Set<String> = []
        for await v in collection.groupsStream() { groups = v; break }
        for await v in collection.entriesStream() { entries = v; break }
        for await v in wants.stream(uid: uid) { wanted = v; break }
        return BackupSnapshot(exportedAt: now(), groups: groups, entries: entries,
                              wanted: wanted.sorted())
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

    /// Launch check: offer a restore when the device is empty and a non-empty backup exists.
    /// Missing/undecodable backups are treated as absent (auto-restore never surfaces errors).
    func offerRestoreIfEligible() async {
        let counts = await currentCounts()
        guard counts.entries == 0, counts.wants == 0 else { return }
        guard let snapshot = try? await loadBackup(),
              Self.restoreEligible(localEntryCount: counts.entries, localWantCount: counts.wants,
                                   backupEntryCount: snapshot.entries.count) else { return }
        offeredSnapshot = snapshot
        restoreOffer = RestoreOffer(entryCount: snapshot.entries.count,
                                    exportedAt: snapshot.exportedAt)
    }

    /// The launch prompt's accept. Re-checks emptiness at acceptance time; a first scan that
    /// landed meanwhile downgrades the offer to warn-and-confirm instead of overwriting.
    func acceptRestore(_ offer: RestoreOffer) async {
        if !offer.requiresOverwriteConfirmation {
            let counts = await currentCounts()
            if counts.entries + counts.wants > 0 {
                restoreOffer = RestoreOffer(entryCount: offer.entryCount,
                                            exportedAt: offer.exportedAt,
                                            requiresOverwriteConfirmation: true)
                return
            }
        }
        restoreOffer = nil
        guard let snapshot = offeredSnapshot else { return }
        offeredSnapshot = nil
        try? await performRestore(snapshot: snapshot)   // failure leaves the collection untouched
    }

    /// Replace the local collection + wishlist with `snapshot` (last-writer-wins by design).
    /// Takes the snapshot explicitly — callers restore exactly what the user was shown, not
    /// whatever the file on disk holds now (a debounced auto-backup can swap it in between).
    /// Throws BackupError so the manual Settings path can surface what went wrong.
    func performRestore(snapshot: BackupSnapshot) async throws {
        try await collection.replaceAll(groups: snapshot.groups, entries: snapshot.entries)
        try await wants.replaceAll(uid: uid, wanted: Set(snapshot.wanted))
    }

    private func currentCounts() async -> (entries: Int, wants: Int) {
        var e = 0, w = 0
        for await v in collection.entriesStream() { e = v.count; break }
        for await v in wants.stream(uid: uid) { w = v.count; break }
        return (e, w)
    }
}
