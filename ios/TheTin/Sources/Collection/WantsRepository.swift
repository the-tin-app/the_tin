import Foundation

protocol WantsRepository {
    func stream(uid: String) -> AsyncStream<[String: WantEntry]>
    /// Replace the whole wishlist in one atomic write. Serves toggles, edits, and backup restore.
    func save(uid: String, entries: [String: WantEntry]) async throws
}

final class InMemoryWantsRepository: WantsRepository, @unchecked Sendable {
    private(set) var stored: [String: WantEntry] = [:]
    private var continuations: [UUID: AsyncStream<[String: WantEntry]>.Continuation] = [:]
    func stream(uid: String) -> AsyncStream<[String: WantEntry]> {
        AsyncStream { cont in
            let id = UUID(); continuations[id] = cont; cont.yield(stored)
            cont.onTermination = { [weak self] _ in self?.continuations[id] = nil }
        }
    }
    func save(uid: String, entries: [String: WantEntry]) async throws {
        stored = entries
        for c in continuations.values { c.yield(stored) }
    }
}
