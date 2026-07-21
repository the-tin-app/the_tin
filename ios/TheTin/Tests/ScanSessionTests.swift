import XCTest
@testable import TheTin

final class ScanSessionTests: XCTestCase {
    private func obs(_ cands: [(String, Int)], _ cov: Double = 0.9, present: Bool = true) -> FrameObservation {
        FrameObservation(candidates: cands.map { (id: $0.0, inliers: $0.1) }, coverage: cov, cardPresent: present)
    }

    func testLocksAfterStabilityWithSeparation() {
        let s = ScanSession()   // tLock 30, R 1.5, K 3, cov 0.8
        XCTAssertEqual(s.ingest(obs([("a", 40), ("b", 5)])), .guide(bestGuess: "a"))
        XCTAssertEqual(s.ingest(obs([("a", 40), ("b", 5)])), .guide(bestGuess: "a"))
        XCTAssertEqual(s.ingest(obs([("a", 40), ("b", 5)])), .lock(cardId: "a"))
    }

    func testAmbiguousWhenSeparationTooLow() {
        let s = ScanSession()
        _ = s.ingest(obs([("a", 40), ("b", 38)]))
        _ = s.ingest(obs([("a", 40), ("b", 38)]))
        XCTAssertEqual(s.ingest(obs([("a", 40), ("b", 38)])), .ambiguous(["a", "b"]))
    }

    func testCoverageGatesLock() {
        let s = ScanSession()
        for _ in 0..<4 { _ = s.ingest(obs([("a", 40)], 0.5)) }  // coverage below min
        XCTAssertEqual(s.ingest(obs([("a", 40)], 0.5)), .guide(bestGuess: "a"))
    }

    func testSuppressesRelockUntilCardLeavesThenRelocks() {
        let s = ScanSession()
        for _ in 0..<3 { _ = s.ingest(obs([("a", 40)])) }         // locks
        XCTAssertEqual(s.ingest(obs([("a", 40)])), .idle)         // still same physical card
        for _ in 0..<12 { _ = s.ingest(obs([], 0.0, present: false)) }  // card left (past grace) → reset
        _ = s.ingest(obs([("a", 40)])); _ = s.ingest(obs([("a", 40)]))
        XCTAssertEqual(s.ingest(obs([("a", 40)])), .lock(cardId: "a"))  // new presentation locks again
    }

    func testAcknowledgeLatchesUntilCardLeavesThenRelocks() {
        let s = ScanSession()
        // Build accumulation that would otherwise separate and auto-lock candidate "a"
        // once ratio gate is crossed (mirrors an ambiguous session the user manually resolves).
        _ = s.ingest(obs([("a", 40), ("b", 38)]))
        _ = s.ingest(obs([("a", 40), ("b", 38)]))
        XCTAssertEqual(s.ingest(obs([("a", 40), ("b", 38)])), .ambiguous(["a", "b"]))

        s.acknowledge(cardId: "a")   // user manually chose a card in the chooser

        // Same physical card still under the camera; separation now crosses the ratio gate,
        // which would normally auto-lock — but must stay idle since the session is latched.
        XCTAssertEqual(s.ingest(obs([("a", 40), ("b", 5)])), .idle)
        XCTAssertEqual(s.ingest(obs([("a", 40), ("b", 5)])), .idle)
        XCTAssertEqual(s.ingest(obs([("a", 40), ("b", 5)])), .idle)

        for _ in 0..<12 { _ = s.ingest(obs([], 0.0, present: false)) }  // card leaves frame (past grace) → reset

        // A fresh presentation can lock again.
        _ = s.ingest(obs([("a", 40)])); _ = s.ingest(obs([("a", 40)]))
        XCTAssertEqual(s.ingest(obs([("a", 40)])), .lock(cardId: "a"))
    }

    // Over a binder the locked card never "leaves the frame" — the next pocket slides in with
    // NO no-card gap, so the graceMisses unlatch can never fire. A clearly different card must
    // release the latch (2026-07-15 binder failure round 2: first card locked, every card
    // after returned .idle forever — 1/9 scanned).
    func testLockReleasesOnCardSwapWithoutNoCardGap() {
        let s = ScanSession()
        for _ in 0..<3 { _ = s.ingest(obs([("a", 40)])) }            // locks "a"
        XCTAssertEqual(s.ingest(obs([("a", 40)])), .idle)            // same card → latched
        // Swap straight to card "b": cardPresent stays true throughout (binder flow).
        _ = s.ingest(obs([("b", 50)]))                               // swap streak 1
        _ = s.ingest(obs([("b", 50)]))                               // swap streak 2
        _ = s.ingest(obs([("b", 50)]))                               // swap streak 3 → release, fresh streak 1
        _ = s.ingest(obs([("b", 50)]))                               // streak 2
        XCTAssertEqual(s.ingest(obs([("b", 50)])), .lock(cardId: "b"),
                       "a different card under the camera must release the lock latch")
    }

    func testLockLatchHoldsAgainstWeakOrSameCardFrames() {
        let s = ScanSession()
        for _ in 0..<3 { _ = s.ingest(obs([("a", 40)])) }            // locks "a"
        // Weak flickers (below tLock) and the locked card itself must NOT release the latch.
        XCTAssertEqual(s.ingest(obs([("b", 10)])), .idle)
        XCTAssertEqual(s.ingest(obs([("b", 15)])), .idle)
        XCTAssertEqual(s.ingest(obs([("b", 12)])), .idle)
        XCTAssertEqual(s.ingest(obs([("a", 40)])), .idle)
        XCTAssertEqual(s.ingest(obs([("a", 40)])), .idle)
    }

    // Once a chooser is shown, the options must FREEZE while the user decides — every
    // subsequent frame of the same card is idle; options never reshuffle under their finger.
    func testChooserLatchesOptionsUntilResolved() {
        let s = ScanSession()
        _ = s.ingest(obs([("a", 40), ("b", 38)]))
        _ = s.ingest(obs([("a", 40), ("b", 38)]))
        XCTAssertEqual(s.ingest(obs([("a", 40), ("b", 38)])), .ambiguous(["a", "b"]))
        XCTAssertEqual(s.ingest(obs([("a", 45), ("c", 40)])), .idle,
                       "chooser must freeze — no reshuffling while the user decides")
        XCTAssertEqual(s.ingest(obs([("c", 60), ("a", 5)])), .idle)
    }

    // A shown chooser is MODAL (Tomas, 2026-07-21): neither a sustained run of a DIFFERENT
    // strong card (swap-release) nor the card leaving the frame (grace) may dismiss it — only
    // the user picking a tile or "None of these" resolves it. Regression for the reported
    // "chooser flashes up then vanishes before I can tap it".
    func testChooserStaysModalUntilUserResolves() {
        let s = ScanSession()
        _ = s.ingest(obs([("a", 40), ("b", 38)]))
        _ = s.ingest(obs([("a", 40), ("b", 38)]))
        XCTAssertEqual(s.ingest(obs([("a", 40), ("b", 38)])), .ambiguous(["a", "b"]))
        // A different strong card dominates well past stabilityK — old code swap-released here.
        for _ in 0..<6 { XCTAssertEqual(s.ingest(obs([("c", 60)])), .idle) }
        // Card leaves the frame well past graceMisses — must still not dismiss the chooser.
        for _ in 0..<15 { XCTAssertEqual(s.ingest(obs([], 0.0, present: false)), .idle) }
        // Only an explicit resolution frees it; scanning then resumes and can lock again.
        s.dismissChooser()
        _ = s.ingest(obs([("a", 40), ("b", 5)])); _ = s.ingest(obs([("a", 40), ("b", 5)]))
        XCTAssertEqual(s.ingest(obs([("a", 40), ("b", 5)])), .lock(cardId: "a"))
    }

    // ~7s without a lock (chooserDeadlineFrames heavy frames) forces the best-4 chooser and
    // freezes it — the user decides instead of the scanner spinning forever.
    func testScanDeadlineForcesChooserAndFreezes() {
        let s = ScanSession()   // chooserDeadlineFrames = 16
        var event: ScanEvent = .idle
        // Weak ungated match: never clears tLock, never reaches the holo confirm path.
        for _ in 0..<16 { event = s.ingest(obs([("a", 15)])) }
        XCTAssertEqual(event, .ambiguous(["a"]),
                       "the deadline must surface the accumulated best options")
        XCTAssertEqual(s.ingest(obs([("a", 15)])), .idle, "deadline chooser freezes scanning")
    }

    // No candidates ever accumulated (OCR pool empty on every frame) → nothing to offer;
    // the deadline must NOT fire an empty chooser.
    func testScanDeadlineWithNoCandidatesKeepsScanning() {
        let s = ScanSession()
        var event: ScanEvent = .idle
        for _ in 0..<20 { event = s.ingest(obs([])) }
        XCTAssertEqual(event, .guide(bestGuess: nil))
    }

    // "None of these — keep scanning": dismissing a chooser resumes scanning with a clean
    // slate — nothing suppressed (a shown option may still be the truth of a LATER card, e.g.
    // binder duplicates), and the same card can re-lock once evidence rebuilds.
    func testDismissChooserResumesScanning() {
        let s = ScanSession()
        _ = s.ingest(obs([("a", 40), ("b", 38)]))
        _ = s.ingest(obs([("a", 40), ("b", 38)]))
        XCTAssertEqual(s.ingest(obs([("a", 40), ("b", 38)])), .ambiguous(["a", "b"]))
        s.dismissChooser()
        _ = s.ingest(obs([("a", 40), ("b", 5)]))
        _ = s.ingest(obs([("a", 40), ("b", 5)]))
        XCTAssertEqual(s.ingest(obs([("a", 40), ("b", 5)])), .lock(cardId: "a"),
                       "dismiss must resume scanning without suppressing the shown options")
    }

    func testRejectSuppressesId() {
        let s = ScanSession()
        for _ in 0..<3 { _ = s.ingest(obs([("a", 40)])) }
        s.reject(cardId: "a")
        for _ in 0..<5 { XCTAssertNotEqual(s.ingest(obs([("a", 40)])), .lock(cardId: "a")) }
    }

    func testGatedWeakMatchOffersConfirmationInsteadOfDropping() {
        let session = ScanSession()   // default tLock=30, gatedConfirmFloor=12
        // Gated candidate with 15 inliers: below tLock (30) but above the confirm floor (12).
        var event: ScanEvent = .idle
        for _ in 0..<3 {   // satisfy stabilityK
            event = session.ingest(FrameObservation(
                candidates: [(id: "pl4-34", inliers: 15)], coverage: 1.0, cardPresent: true, gated: true))
        }
        XCTAssertEqual(event, .ambiguous(["pl4-34"]),
                       "a gated weak match should be offered for confirmation, not silently dropped")
    }

    func testUngatedWeakMatchStillGuidesNotConfirms() {
        let session = ScanSession()
        var event: ScanEvent = .idle
        for _ in 0..<3 {
            event = session.ingest(FrameObservation(
                candidates: [(id: "pl4-34", inliers: 15)], coverage: 1.0, cardPresent: true, gated: false))
        }
        XCTAssertEqual(event, .guide(bestGuess: "pl4-34"),
                       "an ungated weak match must not be offered for confirmation")
    }

    // A hand-held card flickers out of the detector for the odd frame; brief no-card gaps must
    // NOT wipe a strong accumulation, or the lock streak can never build (the on-device
    // "matches at 250 inliers but never locks / stuck on Hold steady" bug).
    func testBriefDetectionDropoutsDoNotPreventLock() {
        let session = ScanSession()   // stabilityK=3, graceMisses=12
        func strong() -> ScanEvent {
            session.ingest(FrameObservation(candidates: [(id: "ex8-63", inliers: 250)],
                                            coverage: 1.0, cardPresent: true))
        }
        func miss() -> ScanEvent {
            session.ingest(FrameObservation(candidates: [], coverage: 0, cardPresent: false))
        }
        _ = strong()                       // streak 1
        for _ in 0..<3 { _ = miss() }      // brief dropout (< graceMisses) — must not reset
        _ = strong()                       // streak 2
        for _ in 0..<3 { _ = miss() }
        let event = strong()               // streak 3 → lock
        XCTAssertEqual(event, .lock(cardId: "ex8-63"),
                       "brief detector dropouts must not stop a strong match from locking")
    }

    func testSustainedAbsenceResetsAccumulation() {
        let session = ScanSession()
        _ = session.ingest(FrameObservation(candidates: [(id: "ex8-63", inliers: 250)],
                                            coverage: 1.0, cardPresent: true))   // streak 1
        for _ in 0..<13 {   // > graceMisses → card genuinely gone → wipe
            _ = session.ingest(FrameObservation(candidates: [], coverage: 0, cardPresent: false))
        }
        // Re-presented card starts fresh: a single detection guides, does not immediately lock.
        let event = session.ingest(FrameObservation(candidates: [(id: "ex8-63", inliers: 250)],
                                                    coverage: 1.0, cardPresent: true))
        XCTAssertEqual(event, .guide(bestGuess: "ex8-63"),
                       "a sustained absence must reset accumulation so a re-presented card starts over")
    }

    // MARK: - OCR-consistency + identical-art-twin lock gate (Task F1a)

    private func obsC(_ cands: [(String, Int)], _ cons: [String: CandidateConsistency], cov: Double = 0.9) -> FrameObservation {
        FrameObservation(candidates: cands.map { (id: $0.0, inliers: $0.1) }, coverage: cov, cardPresent: true, consistency: cons)
    }
    private func good() -> CandidateConsistency { .init(nameAgrees: true, denomOk: true, hasTwinInPool: false) }

    func testConsistentWinnerLocks() {
        let s = ScanSession()
        let cons = ["a": good()]
        _ = s.ingest(obsC([("a", 40), ("b", 5)], cons))
        _ = s.ingest(obsC([("a", 40), ("b", 5)], cons))
        XCTAssertEqual(s.ingest(obsC([("a", 40), ("b", 5)], cons)), .lock(cardId: "a"))
    }

    func testTwinInPoolForcesChooser() {
        let s = ScanSession()
        let cons = ["a": CandidateConsistency(nameAgrees: true, denomOk: true, hasTwinInPool: true)]
        _ = s.ingest(obsC([("a", 40), ("b", 5)], cons))
        _ = s.ingest(obsC([("a", 40), ("b", 5)], cons))
        XCTAssertEqual(s.ingest(obsC([("a", 40), ("b", 5)], cons)), .ambiguous(["a", "b"]),
                       "an identical-art twin in the candidate pool must force a chooser, not a wrong-lock")
    }

    func testDenominatorMismatchForcesChooser() {
        let s = ScanSession()
        let cons = ["a": CandidateConsistency(nameAgrees: true, denomOk: false, hasTwinInPool: false)]
        _ = s.ingest(obsC([("a", 40), ("b", 5)], cons))
        _ = s.ingest(obsC([("a", 40), ("b", 5)], cons))
        XCTAssertEqual(s.ingest(obsC([("a", 40), ("b", 5)], cons)), .ambiguous(["a", "b"]))
    }

    func testNameDisagreementForcesChooser() {
        let s = ScanSession()
        let cons = ["a": CandidateConsistency(nameAgrees: false, denomOk: true, hasTwinInPool: false)]
        _ = s.ingest(obsC([("a", 40), ("b", 5)], cons))
        _ = s.ingest(obsC([("a", 40), ("b", 5)], cons))
        XCTAssertEqual(s.ingest(obsC([("a", 40), ("b", 5)], cons)), .ambiguous(["a", "b"]))
    }

    func testBelowFloorStillGuidesEvenWithGoodConsistency() {
        let s = ScanSession()   // tLock 20
        let cons = ["a": good()]
        _ = s.ingest(obsC([("a", 15)], cons))
        _ = s.ingest(obsC([("a", 15)], cons))
        XCTAssertEqual(s.ingest(obsC([("a", 15)], cons)), .guide(bestGuess: "a"),
                       "the inlier floor gates before consistency matters")
    }

    func testLeaderMissingFromConsistencyKeepsGuidingThenLocks() {
        let session = ScanSession()
        let good = CandidateConsistency(nameAgrees: true, denomOk: true, hasTwinInPool: false)
        let strongFrame = FrameObservation(candidates: [(id: "a", inliers: 50)], coverage: 1.0,
                                           cardPresent: true, gated: true, consistency: ["a": good])
        _ = session.ingest(strongFrame)   // streak 1
        _ = session.ingest(strongFrame)   // streak 2
        // Streak 3 — lock conditions met, but THIS frame's consistency map lacks the leader
        // (empty dict ≠ nil: consistency WAS evaluated, just not for "a").
        let blindFrame = FrameObservation(candidates: [(id: "a", inliers: 50)], coverage: 1.0,
                                          cardPresent: true, gated: true, consistency: [:])
        XCTAssertEqual(session.ingest(blindFrame), .guide(bestGuess: "a"),
                       "unknown consistency must keep guiding, not surface a premature chooser")
        // Next frame re-evaluates consistency for the leader → lock proceeds.
        XCTAssertEqual(session.ingest(strongFrame), .lock(cardId: "a"))
    }
}
