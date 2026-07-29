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
                records += changes.modificationResultsByID.values
                    .compactMap { try? $0.get().record }
                    .compactMap(Self.syncRecord)
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
            let upserts = changes.modifications.compactMap { Self.syncRecord($0.record) }
            let deletes = changes.deletions.compactMap {
                Self.syncRecord(recordName: $0.recordID.recordName, type: $0.recordType)
            }
            if !upserts.isEmpty || !deletes.isEmpty { onRemoteChange?(upserts, deletes) }
        case .sentRecordZoneChanges(let sent):
            lock.withLock {
                for saved in sent.savedRecords { outbound[saved.recordID.recordName] = nil }
            }
            onStatus?(sent.failedRecordSaves.isEmpty ? .synced(Date()) : .failed)
        case .accountChange:
            // Signed out or switched Apple ID: local files keep working, sync goes quiet.
            onStatus?(.unavailable)
        case .willSendChanges, .willFetchChanges:
            onStatus?(.syncing)
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter(context.options.scope.contains)
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] id in
            guard let self, let record = self.lock.withLock({ self.outbound[id.recordName] })
            else { return nil }
            return Self.ckRecord(record, zoneID: self.zoneID)
        }
    }

    // MARK: Record mapping

    private func recordID(_ record: SyncRecord) -> CKRecord.ID {
        CKRecord.ID(recordName: record.key, zoneID: zoneID)
    }

    private static func ckRecord(_ record: SyncRecord, zoneID: CKRecordZone.ID) -> CKRecord {
        let ck = CKRecord(recordType: record.type.rawValue,
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
