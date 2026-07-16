import Foundation

protocol WantsRepository {
    func stream(uid: String) -> AsyncStream<Set<String>>
    func setWanted(uid: String, cardId: String, wanted: Bool) async throws
    /// Replace the entire wishlist in one shot (iCloud backup restore).
    func replaceAll(uid: String, wanted: Set<String>) async throws
}

final class InMemoryWantsRepository: WantsRepository, @unchecked Sendable {
    private(set) var stored: Set<String> = []
    private var continuations: [UUID: AsyncStream<Set<String>>.Continuation] = [:]
    func stream(uid: String) -> AsyncStream<Set<String>> {
        AsyncStream { cont in
            let id = UUID(); continuations[id] = cont; cont.yield(stored)
            cont.onTermination = { [weak self] _ in self?.continuations[id] = nil }
        }
    }
    func setWanted(uid: String, cardId: String, wanted: Bool) async throws {
        if wanted { stored.insert(cardId) } else { stored.remove(cardId) }
        for c in continuations.values { c.yield(stored) }
    }
    func replaceAll(uid: String, wanted: Set<String>) async throws {
        stored = wanted
        for c in continuations.values { c.yield(stored) }
    }
}
