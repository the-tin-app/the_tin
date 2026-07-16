import Foundation

protocol CollectionRepository {
    func groupsStream() -> AsyncStream<[CardGroup]>
    func entriesStream() -> AsyncStream<[CollectionEntry]>
    @discardableResult func createGroup(name: String) async throws -> String
    func renameGroup(id: String, name: String) async throws
    func deleteGroup(id: String) async throws   // cascades to the group's entries
    func reorderGroups(orderedIds: [String]) async throws   // ids not listed keep their relative tail order
    func addEntry(_ entry: CollectionEntry) async throws
    /// Append many entries in one write + one stream notification (CSV import — avoids an
    /// O(n) full-file rewrite + re-diff per row at the 20k-row cap).
    func addEntries(_ entries: [CollectionEntry]) async throws
    func updateEntry(_ entry: CollectionEntry) async throws
    func deleteEntry(id: String) async throws
    /// Replace the entire collection in one shot (iCloud backup restore — preserves ids,
    /// which createGroup/addEntry cannot).
    func replaceAll(groups: [CardGroup], entries: [CollectionEntry]) async throws
}

/// Fully functional fake for tests and previews.
@MainActor
final class InMemoryCollectionRepository: CollectionRepository {
    private(set) var groups: [CardGroup] = []
    private(set) var entries: [CollectionEntry] = []
    private var groupContinuations: [UUID: AsyncStream<[CardGroup]>.Continuation] = [:]
    private var entryContinuations: [UUID: AsyncStream<[CollectionEntry]>.Continuation] = [:]

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

    private func notify() {
        for c in groupContinuations.values { c.yield(groups) }
        for c in entryContinuations.values { c.yield(entries) }
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

    func deleteGroup(id: String) async throws {
        groups.removeAll { $0.id == id }
        entries.removeAll { $0.groupId == id }
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

    func deleteEntry(id: String) async throws {
        entries.removeAll { $0.id == id }
        notify()
    }

    func replaceAll(groups: [CardGroup], entries: [CollectionEntry]) async throws {
        self.groups = groups
        self.entries = entries
        notify()
    }
}
