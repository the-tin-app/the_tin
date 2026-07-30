import Foundation

/// What a synced record is. The raw values are the CloudKit record types — changing one is a
/// schema change, so they are literals rather than derived from the case names.
///
/// `.sealed` exists from day one even though nothing writes it yet: sealed-product ownership is
/// landing on its own branch, and a record type retrofitted later would mean a second
/// "Deploy Schema Changes" round-trip in the CloudKit console. Declaring it costs one line.
enum SyncRecordType: String, CaseIterable, Sendable {
    case group = "Group"
    case entry = "Entry"
    case want = "Want"
    case setGoal = "SetGoal"
    case sealed = "Sealed"
}

/// One record on its way to or from CloudKit.
///
/// The model travels as a single JSON `payload` blob rather than as CloudKit fields. Nothing ever
/// queries CloudKit by field — the app reads local JSON for everything — so fields buy nothing and
/// cost a schema migration every time a model grows, which this one does constantly (`forTrade`,
/// `soldAt`, `soldFor`, `acquiredVia`, `gradingFeeUsd` were each added incrementally). With a blob
/// the schema deploys once and a new field is a Swift change and nothing else. An entry encodes to
/// ~300 bytes against CloudKit's 1 MB record limit.
struct SyncRecord: Equatable, Sendable {
    var type: SyncRecordType
    /// The model's own id — group id, entry id, card id, set id. Per the design's record table.
    var recordName: String
    /// The encoded model, or nil for a record whose existence IS the fact (`.setGoal`).
    var payload: Data?

    /// The CloudKit `CKRecord.ID` name. Record names are unique per ZONE, not per type, so a want
    /// on card "base1" and a goal on set "base1" would otherwise be the same record.
    var key: String { "\(type.rawValue)/\(recordName)" }
}

extension SyncRecord {
    static func group(_ group: CardGroup) throws -> SyncRecord {
        SyncRecord(type: .group, recordName: group.id, payload: try encoder.encode(group))
    }

    static func entry(_ entry: CollectionEntry) throws -> SyncRecord {
        SyncRecord(type: .entry, recordName: entry.id, payload: try encoder.encode(entry))
    }

    static func want(cardId: String, _ want: WantEntry) throws -> SyncRecord {
        SyncRecord(type: .want, recordName: cardId, payload: try encoder.encode(want))
    }

    static func setGoal(_ setId: String) -> SyncRecord {
        SyncRecord(type: .setGoal, recordName: setId, payload: nil)
    }

    /// Keyed by the entry id, not the product id: two rows can hold the same `productId` (buying a
    /// second box at a different price makes its own row with its own cost basis), so keying by
    /// product would make the second one overwrite the first across devices.
    static func sealed(_ entry: SealedEntry) throws -> SyncRecord {
        SyncRecord(type: .sealed, recordName: entry.id, payload: try encoder.encode(entry))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard let payload else {
            throw DecodingError.valueNotFound(T.self, .init(codingPath: [],
                debugDescription: "\(key) carries no payload"))
        }
        return try Self.decoder.decode(T.self, from: payload)
    }

    /// ⚠️ **`.sortedKeys` is load-bearing, not cosmetic.** `JSONEncoder` does NOT otherwise
    /// guarantee byte-identical output for equal values — key order can differ between
    /// invocations — and `SyncDiff` hashes these bytes to decide what changed. Without it, equal
    /// records hash differently: every launch re-pushes the whole collection, and every record
    /// applied from another device echoes straight back. Caught by `SyncDiffTests`, which failed
    /// intermittently until this was set.
    ///
    /// Date strategy is left at the default (a lossless `Double`) rather than ISO-8601 — this blob
    /// is machine-read only, unlike `BackupSnapshot`, which is ISO-8601 to stay human-inspectable.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
    private static let decoder = JSONDecoder()
}
