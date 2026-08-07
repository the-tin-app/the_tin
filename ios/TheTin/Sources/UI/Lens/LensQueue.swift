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
    /// Set by `pause()`, cleared by `drain()` — so resuming is just draining again.
    private var paused = false

    init(work: LensWork, onUpdate: @Sendable @escaping (UUID, [LensCell]) async -> Void) {
        self.work = work
        self.onUpdate = onUpdate
    }

    func enqueue(photoId: UUID) {
        awaitingA.append(photoId)
    }

    /// Stops the drain and **keeps the backlog**, so `drain()` picks it up again later.
    ///
    /// ⚠️ A pause, NOT a discard, and the difference is the whole point. The work is not cheap and
    /// the screen it belongs to can go away mid-read (switching to the Scanner segment, leaving the
    /// Scan tab) — but the photos stay in `LensModel.photos`, and a cell that never gets its pass B
    /// stays `.pending` forever: no row, not counted as unidentified, nothing in the footer. With
    /// no wishlist hits the screen goes back to reading "Take a photo of the cards in front of
    /// you", as if the shutter had never been pressed. That is exactly the silent drop this
    /// feature exists to avoid, and pass B is the slow stage, so the window is wide.
    ///
    /// Precisely how far a running drain gets: a pause landing in pass B finishes that photo's
    /// pass B and stops. A pause landing in detect/pass A finishes pass A for that photo — the
    /// cheap, high-priority stage, and its result must be recorded or the photo is lost, since it
    /// has already left `awaitingA` — and stops before any pass B.
    ///
    /// `reset()` deliberately does NOT use this: it pauses and then drops the whole queue, which
    /// takes the backlog and the cached fingerprints with it. A discard is what Clear means.
    func pause() {
        paused = true
    }

    /// Whether anything is waiting. `LensModel.resume()` checks it so re-entering an idle screen
    /// doesn't flash the "Reading…" state.
    var hasBacklog: Bool { !awaitingA.isEmpty || !awaitingB.isEmpty }

    /// Whether work is still in flight. The caller's spinner reads this after `drain()` returns,
    /// so a call that short-circuited on the guard above doesn't switch the spinner off under the
    /// drain that is still running.
    var isDraining: Bool { draining }

    /// Runs until both stages are empty, or until `pause()` — which it also clears, so resuming a
    /// paused queue is just calling this again. Re-checks `awaitingA` on every iteration, so a
    /// photo captured mid-drain preempts the pass-B backlog rather than queueing behind it.
    ///
    /// Idempotent: a second concurrent call returns immediately, because the loop already running
    /// will pick up anything enqueued since. Callers may therefore always `enqueue` then `drain`.
    func drain() async {
        guard !draining else { return }
        paused = false
        draining = true
        defer { draining = false }
        while !paused, !awaitingA.isEmpty || !awaitingB.isEmpty {
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
