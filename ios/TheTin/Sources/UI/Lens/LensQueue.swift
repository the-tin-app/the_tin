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
    /// Whether a `drain()` is already looping.
    ///
    /// ⚠️ This flag lives HERE, not on the caller, because `enqueue` and the loop condition below
    /// are the two things it has to be consistent with and both are actor state. A caller-side
    /// "am I already draining" flag on the MainActor interleaves: drain #1 finds both lists empty
    /// and returns, shoot #2 enqueues, shoot #2's continuation sees the flag still set and skips
    /// its drain, and only then does shoot #1 clear it — leaving a photo in `awaitingA` with no
    /// drainer, no spinner, and nothing on screen. It self-heals on the next shutter press, which
    /// is exactly the kind of silent miss this feature's copy rules forbid.
    private var draining = false

    init(work: LensWork, onUpdate: @Sendable @escaping (UUID, [LensCell]) async -> Void) {
        self.work = work
        self.onUpdate = onUpdate
    }

    func enqueue(photoId: UUID) {
        awaitingA.append(photoId)
    }

    /// Drops the backlog. A running `drain()` finishes the stage it is in and then exits, because
    /// its loop condition is these two lists.
    ///
    /// Needed because the work is not cheap and the screen it belongs to can go away: Clear, or
    /// switching to the Scanner segment, or leaving the Scan tab. Without it the old queue keeps
    /// both cores busy behind a screen that no longer exists, and the next shutter press builds a
    /// second queue that runs concurrently with the zombie.
    func cancel() {
        awaitingA.removeAll()
        awaitingB.removeAll()
    }

    /// Whether work is still in flight. The caller's spinner reads this after `drain()` returns,
    /// so a call that short-circuited on the guard above doesn't switch the spinner off under the
    /// drain that is still running.
    var isDraining: Bool { draining }

    /// Runs until both stages are empty. Re-checks `awaitingA` on every iteration, so a photo
    /// captured mid-drain preempts the pass-B backlog rather than queueing behind it.
    ///
    /// Idempotent: a second concurrent call returns immediately, because the loop already running
    /// will pick up anything enqueued since. Callers may therefore always `enqueue` then `drain`.
    func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
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
