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

    /// Serializes writes. Each `persist` saves the WHOLE map, so two in flight at once is a
    /// last-writer-wins race — and unstructured `Task`s carry no ordering guarantee, so the
    /// older snapshot can land last and silently discard the newer edit. Hearting a card and
    /// immediately setting its target could lose the target.
    private var writeChain: Task<Void, Never>?

    /// Optimistic save of the whole map; snap back to the last-saved state on write failure so
    /// the UI never shows a change that wasn't persisted.
    private func persist(rollbackTo previous: [String: WantEntry]) {
        let snapshot = entries
        let prior = writeChain
        writeChain = Task { [weak self] in
            await prior?.value            // FIFO — never let an older snapshot overwrite a newer one
            guard let self else { return }
            do { try await self.repo.save(uid: self.uid, entries: snapshot) }
            catch {
                self.entries = previous
                self.onWriteError?("Couldn't update the wishlist — nothing was changed. Check free storage and try again.")
            }
        }
    }
}
