import Foundation
import Observation

struct SetGoalPaths {
    var fileURL: URL
    static func `default`() -> SetGoalPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SetGoalPaths(fileURL: base.appendingPathComponent("set-goals.json"))
    }
}

/// The sets you're collecting.
///
/// A set you're chasing is ONE goal, not N hearts. Bulk-hearting a set's missing cards buried the
/// handful of singles you actually chose, and went stale the moment you bought one — the heart sat
/// there until you remembered to remove it. Storing the goal instead means the gap is *derived*
/// from what you own, so it is correct forever with no maintenance.
///
/// Deliberately just a set of ids: everything else (how many are left, what the gap costs) is
/// computed from the catalog and your collection, so there is no second copy of the truth to drift.
@MainActor @Observable
final class SetGoalsModel {
    private(set) var setIds: Set<String> = []
    private let fileURL: URL
    /// Routes write failures into the same alert sink as collection/wishlist writes.
    var onWriteError: ((String) -> Void)?

    init(paths: SetGoalPaths = .default()) {
        self.fileURL = paths.fileURL
        self.setIds = Self.load(from: paths.fileURL)
    }

    static func load(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    func isCollecting(_ setId: String) -> Bool { setIds.contains(setId) }

    /// Start or stop collecting a set. Optimistic, rolled back if the write fails, so the UI never
    /// shows a goal that wouldn't survive a relaunch.
    func toggle(_ setId: String) {
        let previous = setIds
        if setIds.contains(setId) { setIds.remove(setId) } else { setIds.insert(setId) }
        do { try persist() } catch {
            setIds = previous
            onWriteError?("Couldn't update your sets — nothing was changed. Check free storage and try again.")
        }
    }

    /// Restores a backup's goals wholesale (mirrors `replaceAll` on the collection).
    func replaceAll(_ ids: Set<String>) {
        let previous = setIds
        setIds = ids
        do { try persist() } catch { setIds = previous }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Sorted so the file is stable between writes and diffs cleanly in a backup.
        try JSONEncoder().encode(setIds.sorted()).write(to: fileURL, options: .atomic)
    }
}

/// One chased set's standing: how far in you are, what's left, and what the gap costs.
struct SetGoalProgress: Identifiable {
    let set: SetRecord
    /// Distinct cards owned, capped at the printed total — the same rule `GroupStats.setCompletion`
    /// and the sets grid use, so all three screens agree.
    let owned: Int
    let total: Int
    /// The cards you don't have, cheapest-first so the next easy win is at the top.
    let missingIds: [String]
    /// Market cost of everything still missing. Unpriced cards contribute nothing rather than
    /// silently reading as free — `pricedMissing` says how much of the gap the number covers.
    let gapValue: Double
    let pricedMissing: Int

    // `self.` is load-bearing: inside a computed-property brace the parser reads a bare `set` as
    // the start of a setter definition.
    var id: String { self.set.id }
    var remaining: Int { missingIds.count }
    var isComplete: Bool { missingIds.isEmpty }
    var fraction: Double { total > 0 ? Double(owned) / Double(total) : 0 }
}

enum SetGoals {
    /// "Collect this set" means every card the catalog lists for it — secret rares included.
    /// (Tomas, 2026-07-25: revisit only if testers ask for a rarity ceiling.)
    static func progress(set: SetRecord, cards: [CardRecord], ownedCardIds: Set<String>,
                         prices: [String: Double]) -> SetGoalProgress {
        let missing = cards.filter { !ownedCardIds.contains($0.id) }
            .sorted { (prices[$0.id] ?? .greatestFiniteMagnitude, $0.number)
                    < (prices[$1.id] ?? .greatestFiniteMagnitude, $1.number) }
        let ownedInSet = cards.filter { ownedCardIds.contains($0.id) }.count
        let priced = missing.compactMap { prices[$0.id] }
        return SetGoalProgress(
            set: set,
            // Capped like the sets grid: secret rares push a set's card list past its printed
            // total, and "104/102 collected" reads as a bug.
            owned: min(ownedInSet, set.total),
            total: set.total,
            missingIds: missing.map(\.id),
            gapValue: priced.reduce(0, +),
            pricedMissing: priced.count)
    }

    /// Chased sets, furthest along first — the ones you're closest to finishing are the ones worth
    /// acting on. Completed sets sink to the bottom rather than vanishing, so finishing one is
    /// visible rather than silent.
    static func sorted(_ progress: [SetGoalProgress]) -> [SetGoalProgress] {
        progress.sorted { a, b in
            if a.isComplete != b.isComplete { return !a.isComplete }
            if a.fraction != b.fraction { return a.fraction > b.fraction }
            return a.set.name < b.set.name
        }
    }
}
