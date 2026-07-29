import CloudKit
import Foundation

/// What sync is doing right now. Mirrors `BackupService.Status` — it sits beside it in Settings.
enum SyncStatus: Equatable {
    /// No iCloud account, sync switched off, or the CloudKit entitlement isn't applied yet.
    /// The app behaves exactly as it does without sync: local files stay authoritative.
    case unavailable
    case syncing
    case synced(Date)
    case failed
}

enum SyncEngineError: Error {
    case accountUnavailable
}

/// Seam over `CKSyncEngine`, the way `BackupStore` fronts the iCloud Drive ubiquity container —
/// the codebase already does this twice. Everything above it (the differ, the echo guard, the
/// seeding table, record encoding) is then unit-testable with no CloudKit anywhere, which is the
/// only kind of verification available: the engine itself needs two real devices on one Apple ID.
///
/// Callbacks are `@Sendable` and can fire off the main actor; `SyncService` hops.
protocol SyncEngine: AnyObject {
    /// `(upserts, deletes)` straight from the zone. Deletes carry their type and record name with
    /// a nil payload.
    var onRemoteChange: (@Sendable ([SyncRecord], [SyncRecord]) -> Void)? { get set }
    var onStatus: (@Sendable (SyncStatus) -> Void)? { get set }

    /// Resolve the account, create the zone if needed, and begin syncing. Throws when iCloud is
    /// unavailable — never when it's merely offline (the engine queues).
    func start() async throws
    func stop()
    /// Queue changes. Fire-and-forget: `CKSyncEngine` owns the scheduling and persists its own
    /// pending state across launches, which is why an offline delete needs no tombstone here.
    func send(upserts: [SyncRecord], deletes: [SyncRecord])
    /// Everything currently in the zone. Used once, to decide seeding.
    func fetchAll() async throws -> [SyncRecord]
}

/// The real engine.
///
/// Compiled unconditionally so the compiler checks it, but **never constructed** until the
/// CloudKit entitlement is applied — `SyncService.makeEngine()` gates that on `TIN_CLOUDKIT`,
/// because `CKContainer(identifier:)` traps for a container the app isn't entitled to. See
/// CLAUDE.md, "Rolling out iCloud sync", for the order; getting it wrong fails silently on
/// TestFlight.
final class CloudKitSyncEngine: NSObject, SyncEngine, CKSyncEngineDelegate, @unchecked Sendable {
    static let zoneName = "tin"
    private static let stateKey = "syncEngineState"

    var onRemoteChange: (@Sendable ([SyncRecord], [SyncRecord]) -> Void)?
    var onStatus: (@Sendable (SyncStatus) -> Void)?

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitSyncEngine.zoneName,
                                         ownerName: CKCurrentUserDefaultName)
    private let defaults: UserDefaults
    private var engine: CKSyncEngine?
    /// Records handed to `send` but not yet written, keyed by CloudKit record name, so
    /// `nextRecordZoneChangeBatch` can materialise a `CKRecord` on demand.
    private var outbound: [String: SyncRecord] = [:]
    /// Whether anything failed during the sync cycle currently in flight. Reset when a cycle
    /// opens, so `didFetchChanges`/`didSendChanges` can close it as `.synced` or `.failed`
    /// without overwriting a failure that has already been reported.
    private var cycleFailed = false
    /// The server's own `CKRecord` per record name, as last seen. A save must be built from this
    /// when it exists: CloudKit rejects a save whose change tag it doesn't recognise, and a record
    /// constructed from scratch has no tag at all. Populated from fetches, successful saves, and
    /// the `serverRecord` attached to a `.serverRecordChanged` failure.
    private var serverRecords: [String: CKRecord] = [:]
    private let lock = NSLock()

    init(containerIdentifier: String = "iCloud.ai.reyes.thetin",
         defaults: UserDefaults = .standard) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
        self.defaults = defaults
    }

    func start() async throws {
        guard try await container.accountStatus() == .available else {
            throw SyncEngineError.accountUnavailable
        }
        let state = defaults.data(forKey: Self.stateKey).flatMap {
            try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        var config = CKSyncEngine.Configuration(database: database, stateSerialization: state,
                                                delegate: self)
        config.automaticallySync = true
        let engine = CKSyncEngine(config)
        self.engine = engine
        // Idempotent server-side: saving an existing zone is a no-op.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    func stop() {
        engine = nil
        lock.withLock { outbound.removeAll() }
    }

    func send(upserts: [SyncRecord], deletes: [SyncRecord]) {
        guard let engine else { return }
        lock.withLock { for record in upserts { outbound[record.key] = record } }
        engine.state.add(pendingRecordZoneChanges:
            upserts.map { .saveRecord(recordID($0)) } + deletes.map { .deleteRecord(recordID($0)) })
    }

    func fetchAll() async throws -> [SyncRecord] {
        var records: [SyncRecord] = []
        var token: CKServerChangeToken?
        while true {
            do {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                let fetched = changes.modificationResultsByID.values.compactMap { try? $0.get().record }
                // Cache the change tags now, so the seeding save that follows succeeds first time
                // instead of always costing a `.serverRecordChanged` round trip.
                lock.withLock { for ck in fetched { serverRecords[ck.recordID.recordName] = ck } }
                records += fetched.compactMap(Self.syncRecord)
                guard changes.moreComing else { return records }
                token = changes.changeToken
            } catch let error as CKError
                where error.code == .zoneNotFound || error.code == .userDeletedZone {
                return []   // nothing has ever been written — an empty zone, not a failure
            }
        }
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            defaults.set(try? JSONEncoder().encode(update.stateSerialization), forKey: Self.stateKey)
        case .fetchedRecordZoneChanges(let changes):
            // Keep the server's copy: a CKRecord carries a change tag, and a save built from
            // scratch has none — which CloudKit rejects as `.serverRecordChanged`.
            lock.withLock {
                for m in changes.modifications { serverRecords[m.record.recordID.recordName] = m.record }
                for d in changes.deletions { serverRecords[d.recordID.recordName] = nil }
            }
            let upserts = changes.modifications.compactMap { Self.syncRecord($0.record) }
            let deletes = changes.deletions.compactMap {
                Self.syncRecord(recordName: $0.recordID.recordName, type: $0.recordType)
            }
            if !upserts.isEmpty || !deletes.isEmpty { onRemoteChange?(upserts, deletes) }
        case .sentRecordZoneChanges(let sent):
            lock.withLock {
                for saved in sent.savedRecords {
                    outbound[saved.recordID.recordName] = nil
                    serverRecords[saved.recordID.recordName] = saved
                }
            }
            // Last-writer-wins, actually implemented. A save built without the server's change tag
            // comes back as `.serverRecordChanged` carrying that server record; adopt it, stamp our
            // payload onto it, and re-queue. Without this the record NEVER syncs — it just fails
            // forever — which is what "use this device" hit on every record the other device had
            // already written (observed on device 2026-07-29).
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            for failure in sent.failedRecordSaves {
                let id = failure.record.recordID
                guard let ck = failure.error.serverRecord else { continue }
                lock.withLock { serverRecords[id.recordName] = ck }
                retry.append(.saveRecord(id))
            }
            let unresolved = sent.failedRecordSaves.count - retry.count
            lock.withLock { cycleFailed = unresolved > 0 }
            if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
            onStatus?(unresolved > 0 ? .failed : .synced(Date()))
        case .accountChange:
            // Signed out or switched Apple ID: local files keep working, sync goes quiet.
            onStatus?(.unavailable)
        case .willSendChanges, .willFetchChanges:
            lock.withLock { cycleFailed = false }
            onStatus?(.syncing)
        // A cycle with nothing to send never emits `sentRecordZoneChanges`, and once the zone is
        // seeded that is the steady state — so without closing the cycle here, the first idle
        // fetch latches the UI on "Syncing…" forever. Observed on device 2026-07-29.
        case .didSendChanges, .didFetchChanges:
            onStatus?(lock.withLock { cycleFailed } ? .failed : .synced(Date()))
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter(context.options.scope.contains)
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] id in
            guard let self else { return nil }
            let (record, base) = self.lock.withLock {
                (self.outbound[id.recordName], self.serverRecords[id.recordName])
            }
            guard let record else { return nil }
            return Self.ckRecord(record, zoneID: self.zoneID, base: base)
        }
    }

    // MARK: Record mapping

    private func recordID(_ record: SyncRecord) -> CKRecord.ID {
        CKRecord.ID(recordName: record.key, zoneID: zoneID)
    }

    /// `base` is the server's copy when we have one. Mutating it preserves the change tag, which is
    /// what makes overwriting an existing record succeed instead of failing `.serverRecordChanged`.
    private static func ckRecord(_ record: SyncRecord, zoneID: CKRecordZone.ID,
                                 base: CKRecord? = nil) -> CKRecord {
        let ck = base ?? CKRecord(recordType: record.type.rawValue,
                                  recordID: CKRecord.ID(recordName: record.key, zoneID: zoneID))
        ck["payload"] = record.payload as CKRecordValue?
        return ck
    }

    private static func syncRecord(_ ck: CKRecord) -> SyncRecord? {
        syncRecord(recordName: ck.recordID.recordName, type: ck.recordType,
                   payload: ck["payload"] as? Data)
    }

    private static func syncRecord(recordName: String, type: String,
                                   payload: Data? = nil) -> SyncRecord? {
        guard let kind = SyncRecordType(rawValue: type),
              recordName.hasPrefix(kind.rawValue + "/") else { return nil }
        return SyncRecord(type: kind,
                          recordName: String(recordName.dropFirst(kind.rawValue.count + 1)),
                          payload: payload)
    }
}
