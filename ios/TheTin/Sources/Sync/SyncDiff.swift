import Foundation

/// Turns "here is the current state" into "here is what changed", by diffing the streams the
/// repositories already publish against a map of content hashes.
///
/// Why a diff and not an engine call at each mutation site: calling the engine from every
/// mutation means touching every method on three repositories and being permanently one forgotten
/// call away from a card that silently never syncs. The diff cannot miss a mutation —
/// `LocalCollectionRepository.mutate` rolls back and throws *before* `notify()` when the disk
/// write fails, so a mutation that didn't notify didn't happen. Zero lines change in
/// `LocalCollectionRepository`, `LocalWantsRepository` or `SetGoalsModel`.
///
/// Pure and IO-free on purpose (the shape `PriceAlertsService`'s static functions use), so every
/// decision here is unit-testable with no CloudKit anywhere.
///
/// Each map is scoped to ONE record type — the entries stream knows nothing about groups, and
/// diffing a whole-collection map against an entries-only emission would read as "every group was
/// deleted". `SyncService` keeps one map per `SyncRecordType`.
enum SyncDiff {
    struct Changes: Equatable {
        var upserts: [SyncRecord] = []
        /// Record names (within the type) that are gone.
        var deletes: [String] = []
        /// The map to carry forward.
        var hashes: [String: Int] = [:]

        var isEmpty: Bool { upserts.isEmpty && deletes.isEmpty }
    }

    static func changes(previous: [String: Int], current: [SyncRecord]) -> Changes {
        var result = Changes()
        for record in current {
            let hash = contentHash(record)
            result.hashes[record.recordName] = hash
            if previous[record.recordName] != hash { result.upserts.append(record) }
        }
        result.deletes = previous.keys.filter { result.hashes[$0] == nil }.sorted()
        return result
    }

    /// Fold records that arrived FROM CloudKit into the hash map, before they are written locally.
    ///
    /// Applying a remote record writes to the repository, which notifies, which diffs — and would
    /// push the record straight back, forever. Updating the map at apply time makes the notify
    /// that follows find no delta, so the loop dies on the first pass. One assignment; no origin
    /// flags on the models.
    static func apply(upserts: [SyncRecord], deletes: [String], to hashes: inout [String: Int]) {
        for record in upserts { hashes[record.recordName] = contentHash(record) }
        for name in deletes { hashes[name] = nil }
    }

    /// FNV-1a over the payload. `Hasher` is seeded randomly per process, which would make every
    /// launch's first diff look like the whole collection changed; this is content-addressed and
    /// stable forever. A payloadless record (`.setGoal`) hashes to the basis — existence is the
    /// only fact it carries, so presence in the map is the whole signal.
    private static func contentHash(_ record: SyncRecord) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in record.payload ?? Data() {
            hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3
        }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }
}
