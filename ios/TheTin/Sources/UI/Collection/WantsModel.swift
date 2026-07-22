import Foundation
import Observation

@MainActor @Observable
final class WantsModel {
    private(set) var entries: [String: WantEntry] = [:]
    /// Derived id set — the API every existing consumer (heart, Discover, badges, CSV/print) reads.
    var wanted: Set<String> { Set(entries.keys) }
    private let repo: WantsRepository
    private let uid: String
    /// Routes write failures into the same alert sink as collection writes. Set by AppModel.
    var onWriteError: ((String) -> Void)?

    init(repo: WantsRepository, uid: String) {
        self.repo = repo; self.uid = uid
        Task { for await e in repo.stream(uid: uid) { self.entries = e } }
    }

    func isWanted(_ cardId: String) -> Bool { entries.keys.contains(cardId) }
    func entry(_ cardId: String) -> WantEntry? { entries[cardId] }

    /// Heart on/off. New wishes start at default priority/no-target/no-notes.
    func toggle(_ cardId: String) {
        let previous = entries
        if entries[cardId] == nil { entries[cardId] = WantEntry() } else { entries[cardId] = nil }
        persist(rollbackTo: previous)
    }

    /// Edit an existing entry's priority/target/notes. No-op if the card isn't wanted.
    func update(_ cardId: String, _ mutate: (inout WantEntry) -> Void) {
        guard var e = entries[cardId] else { return }
        let previous = entries
        mutate(&e); entries[cardId] = e
        persist(rollbackTo: previous)
    }

    /// Optimistic save of the whole map; snap back to the last-saved state on write failure so
    /// the UI never shows a change that wasn't persisted.
    private func persist(rollbackTo previous: [String: WantEntry]) {
        let snapshot = entries
        Task {
            do { try await repo.save(uid: uid, entries: snapshot) }
            catch {
                entries = previous
                onWriteError?("Couldn't update the wishlist — nothing was changed. Check free storage and try again.")
            }
        }
    }
}
