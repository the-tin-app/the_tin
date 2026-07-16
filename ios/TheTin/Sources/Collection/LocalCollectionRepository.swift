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
/// pattern as `ScanStagingStore`/`CatalogUpdater`). Read/write failures degrade to in-memory
/// (never crash). NOTE: existing cloud entries do not migrate, and server-side jobs that read
/// `users/{uid}/entries` receive nothing while the collection is local.
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

    private func persist() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
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
        data.groups.append(group)
        persist(); notify()
        return group.id
    }

    func renameGroup(id: String, name: String) async throws {
        guard let i = data.groups.firstIndex(where: { $0.id == id }) else { return }
        data.groups[i].name = name
        persist(); notify()
    }

    func deleteGroup(id: String) async throws {
        data.groups.removeAll { $0.id == id }
        data.entries.removeAll { $0.groupId == id }
        persist(); notify()
    }

    func reorderGroups(orderedIds: [String]) async throws {
        for (i, id) in orderedIds.enumerated() {
            if let idx = data.groups.firstIndex(where: { $0.id == id }) { data.groups[idx].sortOrder = i }
        }
        data.groups.sort { $0.sortOrder < $1.sortOrder }
        persist(); notify()
    }

    func addEntry(_ entry: CollectionEntry) async throws {
        data.entries.append(entry)
        persist(); notify()
    }

    func addEntries(_ newEntries: [CollectionEntry]) async throws {
        data.entries.append(contentsOf: newEntries)
        persist(); notify()
    }

    func updateEntry(_ entry: CollectionEntry) async throws {
        guard let i = data.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        data.entries[i] = entry
        persist(); notify()
    }

    func deleteEntry(id: String) async throws {
        data.entries.removeAll { $0.id == id }
        persist(); notify()
    }

    func replaceAll(groups: [CardGroup], entries: [CollectionEntry]) async throws {
        data = Snapshot(groups: groups, entries: entries)
        persist(); notify()
    }
}
