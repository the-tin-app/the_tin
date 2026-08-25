import CryptoKit
import Foundation
import Observation

/// One backup file's contents: the whole owned collection + wishlist, reusing the models'
/// existing Codable conformances verbatim. `schemaVersion` gates future migrations.
struct BackupSnapshot: Codable, Equatable {
    var schemaVersion: Int = 5
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
    /// v5: binder layouts, keyed by the divider each lays out. Optional + defaulted for the reason
    /// the three fields above document — a v4 backup decodes with this nil, and `performRestore`
    /// then leaves local binders alone rather than clearing them from a file that never knew
    /// about them.
    var binders: [BinderLayout]? = nil
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

    /// A backup in iCloud that another device wrote and this one has not taken on.
    ///
    /// One file, last writer wins — which is fine until two devices are in use, and then the
    /// staler one silently overwrites the fresher. Measured 2026-08-10: an iPad, idle on a
    /// shelf, overwrote the iPhone's backup within ~25 s of every launch and reduced it to its
    /// own months-old collection. Nothing warned, and the only symptom was restored data that
    /// was quietly wrong.
    struct Conflict: Equatable {
        var exportedAt: Date
        var entryCount: Int
    }

    /// Set when a write is refused because the file belongs to another device. Cleared by taking
    /// that backup (`acceptConflict`) or by deliberately overwriting it (`overwriteConflict`).
    private(set) var conflict: Conflict?

    /// `exportedAt` of the last snapshot this device WROTE or RESTORED FROM — the definition of
    /// "the backup is mine". Persisted, so an ordinary relaunch on a one-device setup recognises
    /// its own file instead of treating it as foreign and nagging.
    ///
    /// ⚠️ Deliberately not "the newest date I have seen". The iPad had seen the iPhone's newer
    /// backup and overwrote it anyway; having *read* a file is not having incorporated it.
    private var lastSyncedExportedAt: Date? {
        get { defaults.object(forKey: Self.lastSyncedKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastSyncedKey) }
    }
    private static let lastSyncedKey = "backupLastSyncedExportedAt"

    /// Fingerprint of the last payload this device wrote, `exportedAt` excluded.
    ///
    /// A launch that changes nothing must not produce a backup. The iPad wrote an identical
    /// snapshot within ~25 s of every launch, unprompted — each one a fresh `exportedAt` over the
    /// same data, which made it perpetually "the newest backup" and meant it could never fall
    /// behind the iPhone, so the conflict guard could never fire on it. Nothing new to say ⇒
    /// nothing written ⇒ the device that actually changed keeps the newest file.
    private var lastContentHash: String? {
        get { defaults.string(forKey: Self.lastHashKey) }
        set { defaults.set(newValue, forKey: Self.lastHashKey) }
    }
    private static let lastHashKey = "backupLastContentHash"

    /// Content identity of a snapshot: everything except when it was taken.
    ///
    /// ⚠️ `.sortedKeys` is load-bearing, not tidiness. Without it two encodes of identical data
    /// came out the same LENGTH with different bytes — dictionary keys in hash order — so every
    /// comparison said "changed" and the skip never fired. A fingerprint has to be canonical.
    static func contentHash(_ snapshot: BackupSnapshot) -> String? {
        var stripped = snapshot
        stripped.exportedAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(stripped) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private let store: BackupStore
    /// Photos are NOT in the snapshot; they ride the same container. Injected so tests can point
    /// it at a temp dir.
    private let photos: PhotoStore
    private let collection: CollectionRepository
    private let wants: WantsRepository
    /// Set goals live in their own model, not a repository (a plain file of ids). Optional so
    /// tests and any goal-less wiring construct the service unchanged.
    private let setGoals: SetGoalsModel?
    /// Binder layouts live in their own model too, same shape as `setGoals`. Optional for the
    /// same reason.
    private let binders: BinderLayoutsModel?
    private let uid: String
    /// Where `lastSyncedExportedAt` lives. Injected so two services in one test process are two
    /// devices rather than one — with `.standard` they share the flag and neither sees a conflict.
    private let defaults: UserDefaults
    private let debounce: Duration
    private let now: () -> Date
    private var pendingWrite: Task<Void, Never>?
    private var streamTasks: [Task<Void, Never>] = []

    init(store: BackupStore = ICloudBackupStore(),
         collection: CollectionRepository, wants: WantsRepository,
         setGoals: SetGoalsModel? = nil, binders: BinderLayoutsModel? = nil, uid: String,
         photos: PhotoStore? = nil, defaults: UserDefaults = .standard,
         debounce: Duration = .seconds(5), now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.defaults = defaults
        self.photos = photos ?? .default(mirror: store)
        self.collection = collection
        self.wants = wants
        self.setGoals = setGoals
        self.binders = binders
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
        // Goals have no stream (one small file, written whole), so the model calls back instead.
        // Without this, chasing a set would sit unbacked-up until some other edit happened to fire.
        setGoals?.onChange = { [weak self] in self?.scheduleWrite() }
        binders?.onChange = { [weak self] in self?.scheduleWrite() }
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
    ///
    /// Refuses when the file in iCloud is a newer one this device never took on; see `Conflict`.
    /// `force` is the user answering that prompt with "back up this device anyway".
    func backUpNow(force: Bool = false) async {
        pendingWrite?.cancel()   // a manual backup supersedes any armed debounce
        guard !Task.isCancelled else { return }   // a cancelled caller must not snapshot empty streams
        if !force, let foreign = await foreignBackup() {
            conflict = foreign
            PhotoDiag.record("backUpNow", "REFUSED — newer backup from another device "
                             + "(\(foreign.entryCount) entries, \(foreign.exportedAt))")
            return
        }
        conflict = nil
        let snapshot = await currentSnapshot()
        if let hash = Self.contentHash(snapshot), hash == lastContentHash {
            PhotoDiag.record("backUpNow", "skipped — nothing changed since the last backup")
            return
        }
        // Photos are the one part of an entry that can be on the device and not in the snapshot,
        // because they are only persisted when the form is SAVED. Counting them here separates
        // "the backup didn't carry them" from "the other device didn't pull them" — the two were
        // indistinguishable from the receiving end.
        PhotoDiag.record("backUpNow",
                         "\(PhotoStore.needed(from: snapshot.entries).count) of "
                         + "\(snapshot.entries.count) entries have photos")
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
        // We now own the file — record it, or the very next write would call our own backup
        // foreign and refuse it.
        if case .backedUp = status {
            lastSyncedExportedAt = snapshot.exportedAt
            lastContentHash = Self.contentHash(snapshot)
        }
    }

    /// The backup in iCloud, when it is newer than the one this device last wrote or restored
    /// from — i.e. another device has written since, and overwriting it would destroy that work.
    ///
    /// nil covers every ordinary case: no backup yet, iCloud off, an unreadable file (a write is
    /// the best available repair), or a file this device already owns. Only a readable, strictly
    /// newer, foreign snapshot blocks a write.
    private func foreignBackup() async -> Conflict? {
        guard let remote = try? await loadBackup() else { return nil }
        if let mine = lastSyncedExportedAt, remote.exportedAt <= mine { return nil }
        if lastSyncedExportedAt == nil, remote.entries.isEmpty { return nil }
        return Conflict(exportedAt: remote.exportedAt, entryCount: remote.entries.count)
    }

    /// Take the other device's backup: restore from it, which also makes it ours.
    func acceptConflict() async throws {
        guard conflict != nil else { return }
        let snapshot = try await loadBackup()
        try await performRestore(snapshot: snapshot)
        conflict = nil
    }

    /// Keep this device's data and overwrite the other device's backup. Deliberate, and the only
    /// way past the prompt without losing what is on this device.
    func overwriteConflict() async {
        await backUpNow(force: true)
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
                              setGoals: setGoals?.setIds.sorted(), sealed: sealed,
                              binders: binders?.all)
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
    ///
    /// Also probes for a conflict, so the warning appears when you go looking rather than only
    /// after a write has already been refused — on a device you barely touch, that write might
    /// not come for weeks.
    func refreshStatus() async {
        conflict = await foreignBackup()
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
        // nil = a pre-v5 backup, which says nothing about binders; keep whatever is on the device.
        if let layouts = snapshot.binders { binders?.replaceAll(layouts) }
        // Photos live beside the snapshot, not in it. Pulled down off-main and best-effort: a
        // restored entry whose photo hasn't arrived yet is a far smaller failure than a restore
        // that blocks on a few hundred file downloads.
        // Restoring from it is what makes it ours. Without this the device would refuse to back
        // up afterwards, calling the very snapshot it is now running on "another device's".
        lastSyncedExportedAt = snapshot.exportedAt
        lastContentHash = Self.contentHash(snapshot)
        conflict = nil
        let photos = self.photos
        let needed = PhotoStore.needed(from: snapshot.entries)
        // Both directions. A backup that records photo FILENAMES while those photos are not in
        // iCloud is broken by construction — the restore resolves the names to nothing. So the
        // snapshot write is exactly the moment to make sure what it references is actually there.
        Task.detached(priority: .utility) {
            photos.mirrorDown(needed: needed)
            photos.mirrorSweep(needed: needed)
        }
    }

    private func currentCounts() async -> (entries: Int, wants: Int) {
        var e = 0, w = 0
        for await v in collection.entriesStream() { e = v.count; break }
        for await v in wants.stream(uid: uid) { w = v.count; break }
        return (e, w)
    }
}
