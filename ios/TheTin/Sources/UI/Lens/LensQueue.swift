import Foundation

/// The three stages, injectable so the ordering rule below is testable without a camera, a
/// catalog or a fingerprint pack.
protocol LensWork: Sendable {
    func detect(photoId: UUID) async -> [LensCell]
    func passA(photoId: UUID, cells: [LensCell]) async -> [LensCell]
    func passB(photoId: UUID, cells: [LensCell]) async -> [LensCell]
}

/// Schedules photos through detect → pass A → pass B, with one rule:
///
/// **All of pass A across every queued photo runs before pass B on any of them.**
///
/// Not per-photo A-then-B. The user is standing in a shop deciding whether to keep shooting, and
/// the question in their head is "is anything I want here" — not "what does that one cost". So
/// wishlist hits from the photo just taken beat pricing detail from the first one.
///
/// It also degrades honestly: if pass B is slow on an A10, pass B is merely LATE. Pass A has
/// already answered the question that mattered.
actor LensQueue {
    private let work: LensWork
    private let onUpdate: @Sendable (UUID, [LensCell]) async -> Void

    /// Photos not yet through detect + pass A, in arrival order.
    private var awaitingA: [UUID] = []
    /// Photos through pass A, waiting on pass B.
    private var awaitingB: [(id: UUID, cells: [LensCell])] = []

    init(work: LensWork, onUpdate: @Sendable @escaping (UUID, [LensCell]) async -> Void) {
        self.work = work
        self.onUpdate = onUpdate
    }

    func enqueue(photoId: UUID) {
        awaitingA.append(photoId)
    }

    /// Runs until both stages are empty. Re-checks `awaitingA` on every iteration, so a photo
    /// captured mid-drain preempts the pass-B backlog rather than queueing behind it.
    func drain() async {
        while !awaitingA.isEmpty || !awaitingB.isEmpty {
            if !awaitingA.isEmpty {
                let id = awaitingA.removeFirst()
                let detected = await work.detect(photoId: id)
                await onUpdate(id, detected)
                let afterA = await work.passA(photoId: id, cells: detected)
                await onUpdate(id, afterA)
                awaitingB.append((id, afterA))
                continue                      // ← the priority rule: always re-check A first
            }
            let next = awaitingB.removeFirst()
            let afterB = await work.passB(photoId: next.id, cells: next.cells)
            await onUpdate(next.id, afterB)
        }
    }
}
