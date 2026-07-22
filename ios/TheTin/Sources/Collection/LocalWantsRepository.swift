import Foundation

struct WantsPaths {
    var fileURL: URL
    static func `default`() -> WantsPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return WantsPaths(fileURL: base.appendingPathComponent("wants.json"))
    }
}

/// On-device, offline-only wishlist. Stores `{cardId: WantEntry}` as one atomic JSON file.
/// The `uid` parameter is ignored (wants are per-device). Mirrors `LocalCollectionRepository`'s
/// atomic-file + stream/notify pattern; read/write failures degrade to in-memory (never crash).
@MainActor
final class LocalWantsRepository: WantsRepository {
    private var entries: [String: WantEntry]
    private let fileURL: URL
    private var continuations: [UUID: AsyncStream<[String: WantEntry]>.Continuation] = [:]

    nonisolated init(paths: WantsPaths = .default()) {
        self.fileURL = paths.fileURL
        self.entries = Self.load(from: paths.fileURL)
    }

    /// Current format is a JSON object; the legacy format was a bare id array (`Set<String>`
    /// encoded). Try the object first, then fall back to the array and migrate each id to a
    /// default `WantEntry`. Missing/garbage file → empty. The two formats never collide: an
    /// array can't decode as a dictionary and vice-versa.
    nonisolated private static func load(from url: URL) -> [String: WantEntry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if let dict = try? JSONDecoder().decode([String: WantEntry].self, from: data) { return dict }
        if let ids = try? JSONDecoder().decode([String].self, from: data) {
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, WantEntry()) })
        }
        return [:]
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(entries) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }

    nonisolated func stream(uid: String) -> AsyncStream<[String: WantEntry]> {
        AsyncStream { continuation in
            Task { @MainActor in
                let key = UUID()
                self.continuations[key] = continuation
                continuation.onTermination = { _ in
                    Task { @MainActor in self.continuations[key] = nil }
                }
                continuation.yield(self.entries)
            }
        }
    }

    func save(uid: String, entries: [String: WantEntry]) async throws {
        self.entries = entries
        persist()
        for c in continuations.values { c.yield(self.entries) }
    }
}
