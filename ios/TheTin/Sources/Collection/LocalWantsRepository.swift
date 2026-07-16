import Foundation

struct WantsPaths {
    var fileURL: URL
    static func `default`() -> WantsPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return WantsPaths(fileURL: base.appendingPathComponent("wants.json"))
    }
}

/// On-device, offline-only wishlist (wanted card ids). Replaces `FirestoreWantsRepository`
/// per the local-only decision — hearting a card never leaves the device and needs no auth.
/// The `uid` parameter is ignored: wants are per-device state, so it satisfies the
/// `WantsRepository` contract without keying on identity. Mirrors `LocalCollectionRepository`'s
/// atomic-JSON-file + stream/notify pattern; read/write failures degrade to in-memory
/// (never crash). NOTE: existing cloud wants do not migrate, and wants no longer sync
/// across devices.
@MainActor
final class LocalWantsRepository: WantsRepository {
    private var wanted: Set<String>
    private let fileURL: URL
    private var continuations: [UUID: AsyncStream<Set<String>>.Continuation] = [:]

    // nonisolated so it can be built from AppModel's default-argument closure; it only
    // assigns stored state (matches LocalCollectionRepository's init).
    nonisolated init(paths: WantsPaths = .default()) {
        self.fileURL = paths.fileURL
        self.wanted = (try? Data(contentsOf: paths.fileURL))
            .flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(wanted) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }

    nonisolated func stream(uid: String) -> AsyncStream<Set<String>> {
        AsyncStream { continuation in
            Task { @MainActor in
                let key = UUID()
                self.continuations[key] = continuation
                continuation.onTermination = { _ in
                    Task { @MainActor in self.continuations[key] = nil }
                }
                continuation.yield(self.wanted)
            }
        }
    }

    func setWanted(uid: String, cardId: String, wanted: Bool) async throws {
        if wanted { self.wanted.insert(cardId) } else { self.wanted.remove(cardId) }
        persist()
        for c in continuations.values { c.yield(self.wanted) }
    }

    func replaceAll(uid: String, wanted: Set<String>) async throws {
        self.wanted = wanted
        persist()
        for c in continuations.values { c.yield(self.wanted) }
    }
}
