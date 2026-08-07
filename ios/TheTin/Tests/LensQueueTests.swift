import XCTest
@testable import TheTin

private actor Journal {
    private(set) var events: [String] = []
    func record(_ e: String) { events.append(e) }
}

/// Fake worker: records the order stages ran in, and returns cells that carry the stage in their
/// state so the queue's threading of results is observable.
private struct FakeWork: LensWork {
    let journal: Journal
    var cellsPerPhoto: Int = 2
    /// Called at the start of `passB`, before it records itself — lets a test inject an enqueue or
    /// a pause at a known point in the schedule instead of racing wall-clock timing against
    /// `drain()`. `onPassAStart` is the same seam one stage earlier.
    var onPassBStart: (@Sendable () async -> Void)?
    var onPassAStart: (@Sendable () async -> Void)?

    func detect(photoId: UUID) async -> [LensCell] {
        await journal.record("detect:\(photoId.uuidString.prefix(4))")
        let q = CardQuad(topLeft: .zero, topRight: .zero, bottomLeft: .zero, bottomRight: .zero)
        return (0..<cellsPerPhoto).map { _ in LensCell(quad: q) }
    }
    func passA(photoId: UUID, cells: [LensCell]) async -> [LensCell] {
        await onPassAStart?()
        await journal.record("A:\(photoId.uuidString.prefix(4))")
        return cells.map { var c = $0; c.onWishlist = true; return c }
    }
    func passB(photoId: UUID, cells: [LensCell]) async -> [LensCell] {
        await onPassBStart?()
        await journal.record("B:\(photoId.uuidString.prefix(4))")
        return cells.map { var c = $0; c.state = .identified(cardId: "x", inliers: 99); return c }
    }
}

/// Pauses the queue from inside a stage, exactly once — the fake's hooks fire on every call, so
/// without the latch a resumed drain would pause itself again immediately.
private actor PauseBox {
    private var queue: LensQueue?
    private var fired = false
    func set(_ q: LensQueue) { queue = q }
    func pauseOnce() async {
        guard !fired else { return }
        fired = true
        await queue?.pause()
    }
}

final class LensQueueTests: XCTestCase {

    /// THE rule. Two photos: both A passes must complete before either B pass starts.
    func testAllPassAAcrossEveryPhotoRunsBeforeAnyPassB() async throws {
        let journal = Journal()
        let queue = LensQueue(work: FakeWork(journal: journal), onUpdate: { _, _ in })
        let p1 = UUID(), p2 = UUID()
        await queue.enqueue(photoId: p1)
        await queue.enqueue(photoId: p2)
        await queue.drain()

        let events = await journal.events
        let firstB = try XCTUnwrap(events.firstIndex { $0.hasPrefix("B:") },
                                    "no pass B ran at all: \(events)")
        let lastA = try XCTUnwrap(events.lastIndex { $0.hasPrefix("A:") },
                                   "no pass A ran at all: \(events)")
        XCTAssertLessThan(lastA, firstB,
                          "pass B started before every pass A finished: \(events)")
    }

    /// A photo enqueued while pass B is already running still gets its pass A first — you are
    /// still shooting, and "is anything here I want" outranks pricing what is already known.
    ///
    /// Made deterministic by driving the arrival of p3 from inside the fake worker: p1's passB is
    /// hooked to enqueue p3 the instant it starts, which is a known point in the schedule (p1 and
    /// p2 have both already cleared pass A, p2's passB is still pending), rather than racing a
    /// freestanding Task against drain() on wall-clock timing.
    ///
    /// Asserts against p2's specific pass B, not just "the last B in the log". `a3 < lastB` alone
    /// is satisfied trivially by p3's own pass A preceding p3's own pass B even under a broken
    /// strict-per-photo scheduler (no preemption at all) — that shape was caught by mutation
    /// testing (delete `drain()`'s `continue`) and confirmed against this exact test. Asserting
    /// `A:p3` precedes `B:p2` — a pass B that was already queued and waiting before p3 ever
    /// arrived — is the only ordering that actually proves preemption.
    func testAPhotoAddedMidDrainJumpsAheadOfRemainingPassB() async throws {
        let journal = Journal()
        let p1 = UUID(), p2 = UUID(), p3 = UUID()

        actor QueueBox {
            var queue: LensQueue?
            private var fired = false
            func set(_ q: LensQueue) { queue = q }
            /// Only the FIRST passB call triggers the enqueue — otherwise every later passB call
            /// (p2's, p3's own) would re-fire it too, since the fake's hook isn't naturally
            /// one-shot. Takes the id as a parameter rather than closing over it — a local `actor`
            /// cannot capture a value from its enclosing scope.
            func enqueueOnce(_ id: UUID) async {
                guard !fired else { return }
                fired = true
                await queue?.enqueue(photoId: id)
            }
        }
        let box = QueueBox()

        var work = FakeWork(journal: journal)
        work.onPassBStart = {
            // Fires on p1's passB — the first passB to run, since awaitingB is FIFO and p1 was
            // enqueued first. At this point p1 and p2 have both cleared pass A and are sitting in
            // the B backlog; p3 has not been seen yet.
            await box.enqueueOnce(p3)
        }
        let queue = LensQueue(work: work, onUpdate: { _, _ in })
        await box.set(queue)

        await queue.enqueue(photoId: p1)
        await queue.enqueue(photoId: p2)
        await queue.drain()

        let events = await journal.events
        let a3 = try XCTUnwrap(events.firstIndex(of: "A:\(p3.uuidString.prefix(4))"),
                                "p3's pass A never ran: \(events)")
        let b2 = try XCTUnwrap(events.firstIndex(of: "B:\(p2.uuidString.prefix(4))"),
                                "p2's pass B never ran: \(events)")
        XCTAssertLessThan(a3, b2,
                          "p3's pass A did not preempt p2's already-pending pass B: \(events)")
    }

    /// Not just "at least 3 updates" — a swapped, duplicated, or missing stage would satisfy a
    /// bare count. Each update is tagged by the OBSERVABLE state of its cell (not by a counter),
    /// so this fails if the queue ever publishes the same stage twice or skips one: `.pending` +
    /// `onWishlist == false` can only be detect's result, `.pending` + `onWishlist == true` only
    /// pass A's (pass A is the only stage that flips `onWishlist`), `.identified` only pass B's.
    func testEveryStagePublishesItsResult() async {
        let journal = Journal()
        let updates = Journal()
        let queue = LensQueue(work: FakeWork(journal: journal), onUpdate: { _, cells in
            let stage: String
            switch (cells.first?.state, cells.first?.onWishlist) {
            case (.identified, _): stage = "passB"
            case (.pending, true): stage = "passA"
            case (.pending, false): stage = "detect"
            default: stage = "unexpected:\(String(describing: cells.first))"
            }
            await updates.record(stage)
        })
        let p = UUID()
        await queue.enqueue(photoId: p)
        await queue.drain()
        let seen = await updates.events
        XCTAssertEqual(seen, ["detect", "passA", "passB"],
                       "expected detect → passA → passB in that order, once each: \(seen)")
    }

    /// `drain()` is idempotent, and that is what lets a caller always `enqueue` then `drain`
    /// without tracking whether one is already running.
    ///
    /// ⚠️ The guard has to live on the actor. It was first written as an `isWorking` flag on the
    /// MainActor caller, which cannot be consistent with `awaitingA`: drain #1's loop finds both
    /// lists empty and returns, shoot #2 enqueues, shoot #2's continuation sees the flag still set
    /// and skips its own drain, and only then does shoot #1 clear it — a photo left in `awaitingA`
    /// with no drainer, no spinner, and nothing shown for it.
    ///
    /// Asserted by measuring how much work the nested call does: with the guard it returns without
    /// running a single stage (delta 0); without it, it would drive p3 and p2's pass B to
    /// completion before returning. A "nothing got processed twice" assertion alone would NOT
    /// catch that — two concurrent loops each `removeFirst` under the actor, so they cannot
    /// duplicate an item.
    func testASecondDrainReturnsWithoutRunningAnything() async throws {
        let journal = Journal()
        let p1 = UUID(), p2 = UUID(), p3 = UUID()

        actor DrainBox {
            private var queue: LensQueue?
            private var journal: Journal?
            private var fired = false
            private(set) var stagesRunByNestedDrain = -1
            func set(_ q: LensQueue, _ j: Journal) { queue = q; journal = j }
            /// One-shot, for the same reason `enqueueOnce` above is: the fake's hook fires on
            /// every passB.
            func nestedDrainOnce(_ id: UUID) async {
                guard !fired else { return }
                fired = true
                await queue?.enqueue(photoId: id)
                let before = await journal?.events.count ?? 0
                await queue?.drain()
                let after = await journal?.events.count ?? 0
                stagesRunByNestedDrain = after - before
            }
        }
        let box = DrainBox()

        var work = FakeWork(journal: journal)
        work.onPassBStart = { await box.nestedDrainOnce(p3) }
        let queue = LensQueue(work: work, onUpdate: { _, _ in })
        await box.set(queue, journal)

        await queue.enqueue(photoId: p1)
        await queue.enqueue(photoId: p2)
        await queue.drain()

        let ran = await box.stagesRunByNestedDrain
        XCTAssertEqual(ran, 0, "the second drain ran \(ran) stages instead of returning")

        // …and the outer drain still finished everything, including the photo the nested call
        // enqueued. This is the stranding half: nothing may be left unprocessed.
        let events = await journal.events
        for (label, id) in [("p1", p1), ("p2", p2), ("p3", p3)] {
            let tag = id.uuidString.prefix(4)
            for stage in ["detect:\(tag)", "A:\(tag)", "B:\(tag)"] {
                XCTAssertEqual(events.filter { $0 == stage }.count, 1,
                               "\(label) expected exactly one \(stage): \(events)")
            }
        }
    }

    /// Leaving the screen has to actually stop the work — otherwise the old queue keeps both cores
    /// busy behind a UI that is gone, and the next shutter press builds a second queue that runs
    /// concurrently with the zombie.
    ///
    /// Paused from inside p1's pass B — a known point in the schedule where p2 has cleared pass A
    /// and its pass B is still pending — so the assertion is about a stage that was definitely
    /// queued and definitely did not run, not about wall-clock timing.
    func testPauseDuringPassBStopsBeforeTheNextPhotosPassB() async throws {
        let journal = Journal()
        let p1 = UUID(), p2 = UUID()
        let box = PauseBox()

        var work = FakeWork(journal: journal)
        work.onPassBStart = { await box.pauseOnce() }
        let queue = LensQueue(work: work, onUpdate: { _, _ in })
        await box.set(queue)

        await queue.enqueue(photoId: p1)
        await queue.enqueue(photoId: p2)
        await queue.drain()

        let events = await journal.events
        XCTAssertFalse(events.contains("B:\(p2.uuidString.prefix(4))"),
                       "the drain carried on through the backlog after pause: \(events)")
    }

    /// The pass-A branch is the one that can run a stage MORE than the one it was in: it has
    /// already taken the photo off `awaitingA`, so it must finish pass A and record the result or
    /// the photo is lost outright. What it must NOT do is fall through into pass B — the most
    /// expensive thing in the feature — for a screen that is gone.
    func testPauseDuringPassAStopsBeforeThatPhotosPassB() async throws {
        let journal = Journal()
        let p = UUID()
        let box = PauseBox()

        var work = FakeWork(journal: journal)
        work.onPassAStart = { await box.pauseOnce() }
        let queue = LensQueue(work: work, onUpdate: { _, _ in })
        await box.set(queue)

        await queue.enqueue(photoId: p)
        await queue.drain()

        let events = await journal.events
        let tag = p.uuidString.prefix(4)
        XCTAssertEqual(events, ["detect:\(tag)", "A:\(tag)"],
                       "pass A must complete and pass B must not start: \(events)")
        let held = await queue.hasBacklog
        XCTAssertTrue(held, "the photo was dropped instead of held for resume")
    }

    /// ⚠️ A pause is not a discard, and this is the assertion that keeps it one. A cell whose pass
    /// B never runs stays `.pending` forever: no row, not counted as unidentified, nothing in the
    /// footer — with no wishlist hits the screen reads "Take a photo of the cards in front of you",
    /// as if the shutter had never been pressed.
    func testAPausedQueueResumesAndCompletesItsBacklog() async throws {
        let journal = Journal()
        let p1 = UUID(), p2 = UUID()
        let box = PauseBox()

        var work = FakeWork(journal: journal)
        work.onPassBStart = { await box.pauseOnce() }
        let queue = LensQueue(work: work, onUpdate: { _, _ in })
        await box.set(queue)

        await queue.enqueue(photoId: p1)
        await queue.enqueue(photoId: p2)
        await queue.drain()
        let pending = await queue.hasBacklog
        XCTAssertTrue(pending, "nothing was left to resume — the test proves nothing")

        await queue.drain()          // ← what LensModel.resume() does

        let events = await journal.events
        for (label, id) in [("p1", p1), ("p2", p2)] {
            let tag = id.uuidString.prefix(4)
            for stage in ["detect:\(tag)", "A:\(tag)", "B:\(tag)"] {
                XCTAssertEqual(events.filter { $0 == stage }.count, 1,
                               "\(label) expected exactly one \(stage) after resuming: \(events)")
            }
        }
        let leftover = await queue.hasBacklog
        XCTAssertFalse(leftover)
    }

    func testDrainingAnEmptyQueueIsANoOp() async {
        let journal = Journal()
        let queue = LensQueue(work: FakeWork(journal: journal), onUpdate: { _, _ in })
        await queue.drain()
        let events = await journal.events
        XCTAssertTrue(events.isEmpty)
    }
}
