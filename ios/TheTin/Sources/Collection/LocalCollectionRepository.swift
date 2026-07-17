import Foundation

struct CollectionPaths {
    var fileURL: URL
    static func `default`() -> CollectionPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CollectionPaths(fileURL: base.appendingPathComponent("collection.json"))
    }
}

/// On-device, offline-only owned collection (groups + entries). Replaces
/// `FirestoreCollectionRepository` per the local-only decision — routing/committing a card
/// never leaves the device and needs no auth. Mirrors `InMemoryCollectionRepository`'s
/// stream/notify contract exactly, persisting the whole set to one atomic JSON file (same
/// pattern as `ScanStagingStore`/`CatalogUpdater`). Read failures degrade to in-memory (never
/// crash); a write failure rolls the mutation back and throws, so in-memory state never shows
/// data that wouldn't survive a relaunch. NOTE: existing cloud entries do not migrate, and
/// server-side jobs that read `users/{uid}/entries` receive nothing while the collection is
/// local.
@MainActor
final class LocalCollectionRepository: CollectionRepository {
    private struct Snapshot: Codable {
        var groups: [CardGroup] = []
        var entries: [CollectionEntry] = []
    }

    private var data: Snapshot
    private let fileURL: URL
    private var groupContinuations: [UUID: AsyncStream<[CardGroup]>.Continuation] = [:]
    private var entryContinuations: [UUID: AsyncStream<[CollectionEntry]>.Continuation] = [:]

    // nonisolated so it can be built from AppModel's default-argument closure (matches
    // InMemoryCollectionRepository's implicit nonisolated init); it only assigns stored state.
    nonisolated init(paths: CollectionPaths = .default()) {
        self.fileURL = paths.fileURL
        self.data = (try? Data(contentsOf: paths.fileURL))
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(data).write(to: fileURL, options: .atomic)
    }

    /// Apply a mutation, persist, notify — rolling the mutation back (no notify) if the disk
    /// write fails, so observers only ever see state that's actually on disk.
    private func mutate(_ change: (inout Snapshot) -> Void) throws {
        let backup = data
        change(&data)
        do { try persist() } catch { data = backup; throw error }
        notify()
    }

    nonisolated func groupsStream() -> AsyncStream<[CardGroup]> {
        AsyncStream { continuation in
            Task { @MainActor in
                let key = UUID()
                self.groupContinuations[key] = continuation
                continuation.onTermination = { _ in
                    Task { @MainActor in self.groupContinuations[key] = nil }
                }
                continuation.yield(self.data.groups)
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
                continuation.yield(self.data.entries)
            }
        }
    }

    private func notify() {
        for c in groupContinuations.values { c.yield(data.groups) }
        for c in entryContinuations.values { c.yield(data.entries) }
    }

    func createGroup(name: String) async throws -> String {
        let group = CardGroup(id: UUID().uuidString, name: name,
                              sortOrder: (data.groups.map(\.sortOrder).max() ?? -1) + 1, createdAt: Date())
        try mutate { $0.groups.append(group) }
        return group.id
    }

    func renameGroup(id: String, name: String) async throws {
        guard data.groups.contains(where: { $0.id == id }) else { return }
        try mutate { snapshot in
            if let i = snapshot.groups.firstIndex(where: { $0.id == id }) { snapshot.groups[i].name = name }
        }
    }

    func deleteGroup(id: String) async throws {
        try mutate { snapshot in
            snapshot.groups.removeAll { $0.id == id }
            snapshot.entries.removeAll { $0.groupId == id }
        }
    }

    func reorderGroups(orderedIds: [String]) async throws {
        try mutate { snapshot in
            for (i, id) in orderedIds.enumerated() {
                if let idx = snapshot.groups.firstIndex(where: { $0.id == id }) { snapshot.groups[idx].sortOrder = i }
            }
            snapshot.groups.sort { $0.sortOrder < $1.sortOrder }
        }
    }

    func addEntry(_ entry: CollectionEntry) async throws {
        try mutate { $0.entries.append(entry) }
    }

    func addEntries(_ newEntries: [CollectionEntry]) async throws {
        try mutate { $0.entries.append(contentsOf: newEntries) }
    }

    func updateEntry(_ entry: CollectionEntry) async throws {
        guard data.entries.contains(where: { $0.id == entry.id }) else { return }
        try mutate { snapshot in
            if let i = snapshot.entries.firstIndex(where: { $0.id == entry.id }) { snapshot.entries[i] = entry }
        }
    }

    func deleteEntry(id: String) async throws {
        try mutate { $0.entries.removeAll { $0.id == id } }
    }

    func replaceAll(groups: [CardGroup], entries: [CollectionEntry]) async throws {
        try mutate { $0 = Snapshot(groups: groups, entries: entries) }
    }
}
