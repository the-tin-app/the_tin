import Foundation
import Observation

struct DiscoverSignalsPaths {
    var fileURL: URL
    static func `default`() -> DiscoverSignalsPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DiscoverSignalsPaths(fileURL: base.appendingPathComponent("discover-signals.json"))
    }
}

/// Why a card was rejected. Each case names exactly ONE dimension of the ranker, which is the whole
/// point: "Too expensive" is not a sentiment, it is an instruction to tighten `PriceBand`.
///
/// ⚠️ Adding a case is fine; **renaming a `rawValue` is not** — stored reasons decode by raw value,
/// and an unknown one degrades to "hidden, no reason", silently losing the tuning.
enum DismissReason: String, Codable, CaseIterable, Identifiable, Sendable {
    case tooExpensive
    case notMySpecies
    case wrongEra
    case notMyKind

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tooExpensive: return "Too expensive"
        case .notMySpecies: return "Not my Pokémon"
        case .wrongEra:     return "Wrong era"
        case .notMyKind:    return "Not my kind of card"
        }
    }

    /// What this answer actually moves, shown under the label so the gesture never feels like a
    /// black box.
    var effect: String {
        switch self {
        case .tooExpensive: return "Show me cheaper cards"
        case .notMySpecies: return "Less of this Pokémon"
        case .wrongEra:     return "Less from this generation"
        case .notMyKind:    return "Less of this rarity"
        }
    }

    var systemImage: String {
        switch self {
        case .tooExpensive: return "dollarsign.circle"
        case .notMySpecies: return "bolt.circle"
        case .wrongEra:     return "clock.arrow.circlepath"
        case .notMyKind:    return "square.stack"
        }
    }
}

/// On-device only, never uploaded.
///
/// Every field is a real `Optional`, not a defaulted non-optional: a defaulted property still makes
/// synthesized `Decodable` DEMAND the key, so a file written before a field existed would fail to
/// decode. Same convention as `CollectionEntry.forTrade` and `BackupSnapshot.setGoals`.
///
/// ⚠️ This is deliberately its OWN file rather than a field inside `wants.json`. A failed read here
/// costs the user a handful of thumbs-downs and nothing else — where a failed `wants.json` decode
/// silently emptied the entire wishlist and the next write persisted the emptiness.
struct DiscoverSignalsData: Codable, Equatable {
    /// Every rejected card id, with or without a stated reason. Excluded from recommendations.
    var dismissed: Set<String>?
    /// `cardId` → `DismissReason.rawValue`, for the subset where the user said why.
    ///
    /// ⚠️ Stored as raw EVENTS, not as computed penalties, on purpose: the multipliers are a tuning
    /// choice and will change. Deriving them at load means retuning is a constant edit rather than a
    /// file migration.
    var reasons: [String: String]?
}

/// Reads and writes `discover-signals.json`. Follows `SetGoalsModel` (one small whole-file atomic
/// write plus a change hook) rather than the repository/stream pattern — there is no stream
/// consumer, and the whole file is a few hundred bytes.
@MainActor @Observable
final class DiscoverSignalsModel {
    private(set) var dismissed: Set<String> = []
    private(set) var reasons: [String: DismissReason] = [:]

    /// Bumped on every successful write.
    ///
    /// ⚠️ Load-bearing. `DiscoverView.task(id:)` keys off owned/wanted **counts**, which cannot see
    /// a dismissal — thumbing a card down changes neither count, so without this the recommendation
    /// set would not recompute until the user happened to add or heart something. "Recalculate now"
    /// is the whole point of the gesture.
    private(set) var revision: Int = 0

    /// Routes write failures into the same alert sink as collection/wishlist writes.
    var onWriteError: ((String) -> Void)?

    private let fileURL: URL

    init(paths: DiscoverSignalsPaths = .default()) {
        self.fileURL = paths.fileURL
        let data = Self.load(from: paths.fileURL)
        self.dismissed = data.dismissed ?? []
        self.reasons = (data.reasons ?? [:]).compactMapValues(DismissReason.init(rawValue:))
    }

    /// A missing or corrupt file yields empty signals. No alert, no migration, no recovery attempt —
    /// the file is disposable by design and starting over costs the user nothing they can't redo.
    ///
    /// An unrecognised reason string drops to "dismissed with no reason" rather than failing the
    /// whole decode: losing one card's tuning beats losing every thumbs-down the user ever gave.
    nonisolated static func load(from url: URL) -> DiscoverSignalsData {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(DiscoverSignalsData.self, from: data)
        else { return DiscoverSignalsData() }
        return decoded
    }

    func isDismissed(_ cardId: String) -> Bool { dismissed.contains(cardId) }

    /// Thumb a card down, optionally saying why. Idempotent on the id, but a later call CAN attach
    /// or change the reason — answering the overlay after a plain hide should still tune.
    func dismiss(_ cardId: String, reason: DismissReason? = nil) {
        let wasNew = dismissed.insert(cardId).inserted
        let reasonChanged = reason != nil && reasons[cardId] != reason
        guard wasNew || reasonChanged else { return }
        if let reason { reasons[cardId] = reason }
        persist()
    }

    /// Undo a thumbs-down, and forget why.
    func restore(_ cardId: String) {
        let removed = dismissed.remove(cardId) != nil
        let hadReason = reasons.removeValue(forKey: cardId) != nil
        guard removed || hadReason else { return }
        persist()
    }

    private func persist() {
        revision &+= 1
        do {
            let payload = DiscoverSignalsData(dismissed: dismissed,
                                              reasons: reasons.mapValues(\.rawValue))
            try JSONEncoder().encode(payload).write(to: fileURL, options: .atomic)
        } catch {
            onWriteError?("Couldn't save your Discover preferences: \(error.localizedDescription)")
        }
    }
}
