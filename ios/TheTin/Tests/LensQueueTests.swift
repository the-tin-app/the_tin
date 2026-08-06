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
    /// Called at the start of `passB`, before it records itself — lets a test inject an enqueue at
    /// a known point in the schedule instead of racing wall-clock timing against `drain()`.
    var onPassBStart: (@Sendable () async -> Void)?

    func detect(photoId: UUID) async -> [LensCell] {
        await journal.record("detect:\(photoId.uuidString.prefix(4))")
        let q = CardQuad(topLeft: .zero, topRight: .zero, bottomLeft: .zero, bottomRight: .zero)
        return (0..<cellsPerPhoto).map { _ in LensCell(quad: q) }
    }
    func passA(photoId: UUID, cells: [LensCell]) async -> [LensCell] {
        await journal.record("A:\(photoId.uuidString.prefix(4))")
        return cells.map { var c = $0; c.onWishlist = true; return c }
    }
    func passB(photoId: UUID, cells: [LensCell]) async -> [LensCell] {
        await onPassBStart?()
        await journal.record("B:\(photoId.uuidString.prefix(4))")
        return cells.map { var c = $0; c.state = .identified(cardId: "x", inliers: 99); return c }
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

    func testDrainingAnEmptyQueueIsANoOp() async {
        let journal = Journal()
        let queue = LensQueue(work: FakeWork(journal: journal), onUpdate: { _, _ in })
        await queue.drain()
        let events = await journal.events
        XCTAssertTrue(events.isEmpty)
    }
}
