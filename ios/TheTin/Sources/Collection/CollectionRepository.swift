import Foundation

protocol CollectionRepository {
    func groupsStream() -> AsyncStream<[CardGroup]>
    func entriesStream() -> AsyncStream<[CollectionEntry]>
    @discardableResult func createGroup(name: String) async throws -> String
    func renameGroup(id: String, name: String) async throws
    /// `keepingEntries` moves the group's entries to "No divider" (groupId "") instead of
    /// cascading the delete to them. One transaction either way.
    func deleteGroup(id: String, keepingEntries: Bool) async throws
    func reorderGroups(orderedIds: [String]) async throws   // ids not listed keep their relative tail order
    func addEntry(_ entry: CollectionEntry) async throws
    /// Append many entries in one write + one stream notification (CSV import — avoids an
    /// O(n) full-file rewrite + re-diff per row at the 20k-row cap).
    func addEntries(_ entries: [CollectionEntry]) async throws
    func updateEntry(_ entry: CollectionEntry) async throws
    /// Apply many entry edits in one write + one stream notification: `updated` written back by
    /// id, `deletedIds` removed. Bulk refiling — looping `updateEntry` would rewrite the whole
    /// file once per card (same reason `addEntries` exists).
    func applyEntryEdits(updated: [CollectionEntry], deletedIds: [String]) async throws
    func deleteEntry(id: String) async throws

    /// The sealed products you own. Its own stream, not folded into `entriesStream`, because a
    /// sealed box is not a card: it has no condition, grade, printing or card id, and every one
    /// of the ~forty consumers of `entriesStream` would have had to learn to skip it.
    func sealedStream() -> AsyncStream<[SealedEntry]>
    func addSealed(_ entry: SealedEntry) async throws
    func updateSealed(_ entry: SealedEntry) async throws
    func deleteSealed(id: String) async throws

    /// Replace the entire collection in one shot (iCloud backup restore, undo — preserves ids,
    /// which createGroup/addEntry cannot).
    ///
    /// `sealed` is REQUIRED, not defaulted. A caller that rebuilt the file from groups + entries
    /// alone would silently delete every sealed product in the tin, and a default would let that
    /// happen quietly at each of the two call sites (undo and restore) rather than failing to
    /// compile until each has said what it means to do with sealed.
    func replaceAll(groups: [CardGroup], entries: [CollectionEntry],
                    sealed: [SealedEntry]) async throws
}

/// Fully functional fake for tests and previews.
@MainActor
final class InMemoryCollectionRepository: CollectionRepository {
    private(set) var groups: [CardGroup] = []
    private(set) var entries: [CollectionEntry] = []
    private(set) var sealed: [SealedEntry] = []
    private var groupContinuations: [UUID: AsyncStream<[CardGroup]>.Continuation] = [:]
    private var entryContinuations: [UUID: AsyncStream<[CollectionEntry]>.Continuation] = [:]
    private var sealedContinuations: [UUID: AsyncStream<[SealedEntry]>.Continuation] = [:]

    nonisolated func groupsStream() -> AsyncStream<[CardGroup]> {
        AsyncStream { continuation in
            Task { @MainActor in
                let key = UUID()
                self.groupContinuations[key] = continuation
                continuation.onTermination = { _ in
                    Task { @MainActor in self.groupContinuations[key] = nil }
                }
                continuation.yield(self.groups)
            }
        }
    }

    nonisolated func entriesStream() -> AsyncStream<[CollectionEntry]> {
        AsyncStream { continuation in
            Task { @MainActor in
                let key = UUID()
                self.entryContinuations[key] = continuation
                continuation.onTermination = { _ in
                    Task { @MainActor in self.entryContinuations[key] = nil }
                }
                continuation.yield(self.entries)
            }
        }
    }

    nonisolated func sealedStream() -> AsyncStream<[SealedEntry]> {
        AsyncStream { continuation in
            Task { @MainActor in
                let key = UUID()
                self.sealedContinuations[key] = continuation
                continuation.onTermination = { _ in
                    Task { @MainActor in self.sealedContinuations[key] = nil }
                }
                continuation.yield(self.sealed)
            }
        }
    }

    private func notify() {
        for c in groupContinuations.values { c.yield(groups) }
        for c in entryContinuations.values { c.yield(entries) }
        for c in sealedContinuations.values { c.yield(sealed) }
    }

    func createGroup(name: String) async throws -> String {
        let group = CardGroup(id: UUID().uuidString, name: name,
                              sortOrder: (groups.map(\.sortOrder).max() ?? -1) + 1, createdAt: Date())
        groups.append(group)
        notify()
        return group.id
    }

    func renameGroup(id: String, name: String) async throws {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = name
        notify()
    }

    func deleteGroup(id: String, keepingEntries: Bool = false) async throws {
        groups.removeAll { $0.id == id }
        if keepingEntries {
            for i in entries.indices where entries[i].groupId == id { entries[i].groupId = "" }
        } else {
            entries.removeAll { $0.groupId == id }
        }
        notify()
    }

    func reorderGroups(orderedIds: [String]) async throws {
        for (i, id) in orderedIds.enumerated() {
            if let idx = groups.firstIndex(where: { $0.id == id }) { groups[idx].sortOrder = i }
        }
        groups.sort { $0.sortOrder < $1.sortOrder }
        notify()
    }

    func addEntry(_ entry: CollectionEntry) async throws {
        entries.append(entry)
        notify()
    }

    func addEntries(_ newEntries: [CollectionEntry]) async throws {
        entries.append(contentsOf: newEntries)
        notify()
    }

    func updateEntry(_ entry: CollectionEntry) async throws {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i] = entry
        notify()
    }

    func applyEntryEdits(updated: [CollectionEntry], deletedIds: [String]) async throws {
        let deleted = Set(deletedIds)
        entries.removeAll { deleted.contains($0.id) }
        for entry in updated {
            if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = entry }
            else { entries.append(entry) }
        }
        notify()
    }

    func deleteEntry(id: String) async throws {
        entries.removeAll { $0.id == id }
        notify()
    }

    func addSealed(_ entry: SealedEntry) async throws {
        sealed.append(entry)
        notify()
    }

    func updateSealed(_ entry: SealedEntry) async throws {
        guard let i = sealed.firstIndex(where: { $0.id == entry.id }) else { return }
        sealed[i] = entry
        notify()
    }

    func deleteSealed(id: String) async throws {
        sealed.removeAll { $0.id == id }
        notify()
    }

    func replaceAll(groups: [CardGroup], entries: [CollectionEntry],
                    sealed: [SealedEntry]) async throws {
        self.groups = groups
        self.entries = entries
        self.sealed = sealed
        notify()
    }
}
