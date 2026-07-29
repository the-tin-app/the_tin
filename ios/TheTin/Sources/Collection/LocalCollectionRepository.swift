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
        /// Sealed products you own. A real `Optional`, NOT `= []`: a defaulted non-optional still
        /// makes synthesized `Decodable` *demand* the key, so every `collection.json` written
        /// before sealed existed would fail to decode — and this repository degrades a read
        /// failure to an empty in-memory collection, so the whole tin would silently vanish.
        /// Same convention as `CollectionEntry.forTrade`/`soldAt`/`acquiredVia`.
        var sealed: [SealedEntry]? = nil
    }

    private var data: Snapshot
    private let fileURL: URL
    private var groupContinuations: [UUID: AsyncStream<[CardGroup]>.Continuation] = [:]
    private var entryContinuations: [UUID: AsyncStream<[CollectionEntry]>.Continuation] = [:]
    private var sealedContinuations: [UUID: AsyncStream<[SealedEntry]>.Continuation] = [:]

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

    nonisolated func sealedStream() -> AsyncStream<[SealedEntry]> {
        AsyncStream { continuation in
            Task { @MainActor in
                let key = UUID()
                self.sealedContinuations[key] = continuation
                continuation.onTermination = { _ in
                    Task { @MainActor in self.sealedContinuations[key] = nil }
                }
                continuation.yield(self.data.sealed ?? [])
            }
        }
    }

    private func notify() {
        for c in groupContinuations.values { c.yield(data.groups) }
        for c in entryContinuations.values { c.yield(data.entries) }
        for c in sealedContinuations.values { c.yield(data.sealed ?? []) }
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

    func deleteGroup(id: String, keepingEntries: Bool = false) async throws {
        try mutate { snapshot in
            snapshot.groups.removeAll { $0.id == id }
            if keepingEntries {
                for i in snapshot.entries.indices where snapshot.entries[i].groupId == id {
                    snapshot.entries[i].groupId = ""
                }
            } else {
                snapshot.entries.removeAll { $0.groupId == id }
            }
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

    func applyEntryEdits(updated: [CollectionEntry], deletedIds: [String]) async throws {
        let deleted = Set(deletedIds)
        try mutate { snapshot in
            snapshot.entries.removeAll { deleted.contains($0.id) }
            for entry in updated {
                if let i = snapshot.entries.firstIndex(where: { $0.id == entry.id }) {
                    snapshot.entries[i] = entry
                } else {
                    snapshot.entries.append(entry)
                }
            }
        }
    }

    func deleteEntry(id: String) async throws {
        try mutate { $0.entries.removeAll { $0.id == id } }
    }

    // MARK: Sealed products
    //
    // `data.sealed` stays nil until something is actually written, so a collection that has never
    // owned a sealed product keeps writing exactly the file it always did — no new key appears,
    // and nothing older reading it sees a shape it doesn't know.

    func addSealed(_ entry: SealedEntry) async throws {
        try mutate { $0.sealed = ($0.sealed ?? []) + [entry] }
    }

    func updateSealed(_ entry: SealedEntry) async throws {
        guard data.sealed?.contains(where: { $0.id == entry.id }) == true else { return }
        try mutate { snapshot in
            if let i = snapshot.sealed?.firstIndex(where: { $0.id == entry.id }) {
                snapshot.sealed?[i] = entry
            }
        }
    }

    func deleteSealed(id: String) async throws {
        try mutate { $0.sealed?.removeAll { $0.id == id } }
    }

    func replaceAll(groups: [CardGroup], entries: [CollectionEntry],
                    sealed: [SealedEntry]) async throws {
        // Empty stays nil rather than becoming `[]`, so restoring a backup into a tin that has
        // never held sealed leaves the file byte-identical to what it was.
        try mutate { $0 = Snapshot(groups: groups, entries: entries,
                                   sealed: sealed.isEmpty ? nil : sealed) }
    }
}
