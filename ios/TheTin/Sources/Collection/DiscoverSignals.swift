import Foundation
import Observation

struct DiscoverSignalsPaths {
    var fileURL: URL
    static func `default`() -> DiscoverSignalsPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DiscoverSignalsPaths(fileURL: base.appendingPathComponent("discover-signals.json"))
    }
}

/// What the collector has told Discover directly, as opposed to what we inferred from their
/// collection. On-device only, never uploaded.
///
/// Every field is a real `Optional`, not a defaulted non-optional: a defaulted property still makes
/// synthesized `Decodable` DEMAND the key, so a file written before a field existed would fail to
/// decode. Same convention as `CollectionEntry.forTrade` and `BackupSnapshot.setGoals`.
///
/// ⚠️ This is deliberately its OWN file rather than a field inside `wants.json`. A failed read here
/// costs the user a handful of thumbs-downs and nothing else — where a failed `wants.json` decode
/// silently emptied the entire wishlist and the next write persisted the emptiness.
struct DiscoverSignalsData: Codable, Equatable {
    /// Card ids the user actively thumbed down. Excluded from every recommendation.
    var dismissed: Set<String>?
}

/// Reads and writes `discover-signals.json`. Follows `SetGoalsModel` (one small whole-file atomic
/// write plus a change hook) rather than the repository/stream pattern — there is no stream
/// consumer, and the whole file is a few hundred bytes.
@MainActor @Observable
final class DiscoverSignalsModel {
    private(set) var dismissed: Set<String> = []

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
        self.dismissed = Self.load(from: paths.fileURL).dismissed ?? []
    }

    /// A missing or corrupt file yields empty signals. No alert, no migration, no recovery attempt —
    /// the file is disposable by design and starting over costs the user nothing they can't redo.
    nonisolated static func load(from url: URL) -> DiscoverSignalsData {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(DiscoverSignalsData.self, from: data)
        else { return DiscoverSignalsData() }
        return decoded
    }

    func isDismissed(_ cardId: String) -> Bool { dismissed.contains(cardId) }

    /// Thumb a card down. Idempotent.
    func dismiss(_ cardId: String) {
        guard dismissed.insert(cardId).inserted else { return }
        persist()
    }

    /// Undo a thumbs-down.
    func restore(_ cardId: String) {
        guard dismissed.remove(cardId) != nil else { return }
        persist()
    }

    private func persist() {
        revision &+= 1
        do {
            let data = try JSONEncoder().encode(DiscoverSignalsData(dismissed: dismissed))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            onWriteError?("Couldn't save your Discover preferences: \(error.localizedDescription)")
        }
    }
}
