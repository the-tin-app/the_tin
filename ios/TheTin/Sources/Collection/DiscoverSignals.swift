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
/// Why a card was rejected.
///
/// ⚠️ **Two of these tune nothing, deliberately.** `notMySpecies` and `wrongEra` name a dimension
/// the ranker holds, so they move it. `dontLikeArt` and `notWorthThisPrice` do not, and Tomas's
/// reasoning is why: *"maybe I just don't like that art by that artist but I like other art by that
/// artist."* An artist-level penalty would be wrong and a rarity-level one would be guessing, so
/// they hide the card and record the statement without acting on it.
///
/// **The recording is the point.** Reasons are stored as raw EVENTS with timestamps, so a later
/// version can learn from accumulated history — nine "don't like the art" taps that turn out to
/// share a finish — without re-teaching. This is what raw-event storage was for.
///
/// ⚠️ `tooExpensive` was REMOVED. It duplicated, invisibly, what `PriceTiers` now states visibly and
/// editably. Stored events with that raw value decode to nil and degrade to a plain hide, which is
/// the correct outcome: the card stays hidden, no hidden price cut is derived from it.
///
/// ⚠️ Adding a case is fine; **renaming a `rawValue` is not** — stored reasons decode by raw value,
/// and an unknown one silently becomes "hidden, no reason".
enum DismissReason: String, Codable, CaseIterable, Identifiable, Sendable {
    case notMySpecies
    case wrongEra
    case dontLikeArt
    case notWorthThisPrice

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notMySpecies:      return "I don't like this Pokémon"
        case .wrongEra:          return "I don't like this generation"
        case .dontLikeArt:       return "I just don't like the art"
        case .notWorthThisPrice: return "Not worth this price"
        }
    }

    /// Two-line label for the card-sized 2×2 panel, which is ~110pt wide on the Discover home row.
    var shortLabel: String {
        switch self {
        case .notMySpecies:      return "Not my\nPokémon"
        case .wrongEra:          return "Wrong\ngeneration"
        case .dontLikeArt:       return "Don't like\nthe art"
        case .notWorthThisPrice: return "Not worth\nthis price"
        }
    }

    /// What this answer actually moves, shown under the label so the gesture is never a black box.
    ///
    /// ⚠️ The two hide-only cases say so honestly rather than implying a tuning that will not happen.
    var effect: String {
        switch self {
        case .notMySpecies:      return "Less of this Pokémon"
        case .wrongEra:          return "Less from this generation"
        case .dontLikeArt:       return "Hides this card"
        case .notWorthThisPrice: return "Hides this card"
        }
    }

    var systemImage: String {
        switch self {
        case .notMySpecies:      return "bolt.circle"
        case .wrongEra:          return "clock.arrow.circlepath"
        case .dontLikeArt:       return "paintpalette"
        case .notWorthThisPrice: return "dollarsign.circle"
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
    /// `cardId` → when the user said it. Feeds the half-life in `DiscoverFeedback`.
    ///
    /// ⚠️ A PARALLEL map rather than restructuring `reasons` into objects, so a file written before
    /// this existed decodes untouched — the one already on the device is 99 bytes of `dismissed` +
    /// `reasons`. A MISSING entry means **full strength**, not fully decayed: treating an unknown
    /// age as old would silently void every signal given before decay shipped.
    var at: [String: Date]?
}

/// Reads and writes `discover-signals.json`. Follows `SetGoalsModel` (one small whole-file atomic
/// write plus a change hook) rather than the repository/stream pattern — there is no stream
/// consumer, and the whole file is a few hundred bytes.
@MainActor @Observable
final class DiscoverSignalsModel {
    private(set) var dismissed: Set<String> = []
    private(set) var reasons: [String: DismissReason] = [:]
    /// When each signal was given. Absent for anything recorded before timestamps shipped.
    private(set) var at: [String: Date] = [:]

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
        self.at = data.at ?? [:]
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
    /// `now` is injected so the decay in `DiscoverFeedback` is testable without a clock.
    ///
    /// Attaching a reason to an already-hidden card RESTAMPS it: that is a new statement about the
    /// card, and filing it under the original hide's date would start the answer half-decayed.
    func dismiss(_ cardId: String, reason: DismissReason? = nil, now: Date = Date()) {
        let wasNew = dismissed.insert(cardId).inserted
        let reasonChanged = reason != nil && reasons[cardId] != reason
        guard wasNew || reasonChanged else { return }
        if let reason { reasons[cardId] = reason }
        at[cardId] = now
        persist()
    }

    /// Undo a thumbs-down, and forget why.
    func restore(_ cardId: String) {
        let removed = dismissed.remove(cardId) != nil
        let hadReason = reasons.removeValue(forKey: cardId) != nil
        at.removeValue(forKey: cardId)
        guard removed || hadReason else { return }
        persist()
    }

    private func persist() {
        revision &+= 1
        do {
            let payload = DiscoverSignalsData(dismissed: dismissed,
                                              reasons: reasons.mapValues(\.rawValue),
                                              at: at)
            try JSONEncoder().encode(payload).write(to: fileURL, options: .atomic)
        } catch {
            onWriteError?("Couldn't save your Discover preferences: \(error.localizedDescription)")
        }
    }
}
