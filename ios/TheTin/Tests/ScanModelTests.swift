import XCTest
import CoreVideo
@testable import TheTin

@MainActor
final class ScanModelTests: XCTestCase {
    private func bundle() -> Bundle { Bundle(for: Self.self) }

    // `ScanModel.isLookUpMode` seeds itself from `AppConfig.scanLookUpMode` and its `didSet`
    // writes straight back to UserDefaults — so the look-up tests below used to leave the flag
    // ON, in a domain that survives the test process. Every ScanModel built afterwards then
    // started in look-up mode and staged nothing, which took out `testLockAppends…` (and, via
    // its `staging.drafts[0]`, the entire suite with an index-out-of-range fatal) on the NEXT
    // run rather than this one. Pin it at both ends: a known state going in, a clean one coming
    // out, so no test can depend on — or poison — ambient device state.
    /// Every persisted scanner setting belongs in both of these. `scanCondition` is the second
    /// one and arrived knowing exactly how the first went wrong.
    override func setUp() async throws {
        try await super.setUp()
        AppConfig.scanLookUpMode = false
        AppConfig.scanCondition = .nm
    }

    override func tearDown() async throws {
        AppConfig.scanLookUpMode = false
        AppConfig.scanCondition = .nm
        try await super.tearDown()
    }

    private struct ReplaySource: FrameSource {
        let buffer: CVPixelBuffer; let count: Int
        func stream() -> AsyncStream<CVPixelBuffer> {
            AsyncStream { cont in for _ in 0..<count { cont.yield(buffer) }; cont.finish() }
        }
    }

    /// Replays like `ReplaySource` and records the frame-rate transitions the model asks for,
    /// so the camera throttling can be asserted without a camera.
    private final class ThrottleSpySource: FrameSource, @unchecked Sendable {
        let buffer: CVPixelBuffer; let count: Int
        private(set) var idleStates: [Bool] = []
        init(buffer: CVPixelBuffer, count: Int) { self.buffer = buffer; self.count = count }
        func stream() -> AsyncStream<CVPixelBuffer> {
            AsyncStream { cont in for _ in 0..<count { cont.yield(buffer) }; cont.finish() }
        }
        func setIdle(_ idle: Bool) { idleStates.append(idle) }
    }

    // The fingerprint fixture ids (card_a/card_b) aren't real catalog cards, so real
    // OCR-narrowing can't produce them — inject a deterministic stub pool so these staging
    // regression tests don't depend on OCR/catalog fixture alignment (recognition accuracy
    // is covered end-to-end in Phase G).
    private struct StubNarrowing: CandidateNarrowing {
        func pool(fields: OcrFields) -> [String] { ["card_a"] }
        func consistency(cardId: String, fields: OcrFields, pool: Set<String>) -> CandidateConsistency {
            .init(nameAgrees: true, denomOk: true, hasTwinInPool: false)
        }
    }

    // Same pool as StubNarrowing (card_a still RANSAC-confirms as the visual winner), but
    // reports a twin-in-pool for the winner. This proves the pipeline actually threads the
    // consistency map end-to-end: the ScanSession gate must fall back to `.ambiguous` (chooser)
    // instead of `.lock` whenever the visual winner has a twin present in the candidate pool,
    // even though nameAgrees/denomOk are otherwise satisfied. A regression that drops the
    // consistency computation (passes `consistency: nil`) would fall through to the gate's
    // visual-only backward-compat branch and lock anyway — this test only passes when the map
    // is genuinely computed and threaded.
    private struct TwinStub: CandidateNarrowing {
        func pool(fields: OcrFields) -> [String] { ["card_a"] }
        func consistency(cardId: String, fields: OcrFields, pool: Set<String>) -> CandidateConsistency {
            .init(nameAgrees: true, denomOk: true, hasTwinInPool: true)
        }
    }

    /// Counts `pool(fields:)` calls so the OCR/pool reuse can be asserted rather than assumed.
    /// `poolIds` is injectable so a test can hand the pipeline a pool that does NOT explain the
    /// plate — the binder-swap case.
    private final class CountingNarrowing: CandidateNarrowing, @unchecked Sendable {
        let poolIds: [String]
        private(set) var calls = 0
        init(poolIds: [String]) { self.poolIds = poolIds }
        func pool(fields: OcrFields) -> [String] { calls += 1; return poolIds }
        func consistency(cardId: String, fields: OcrFields, pool: Set<String>) -> CandidateConsistency {
            .init(nameAgrees: true, denomOk: true, hasTwinInPool: false)
        }
    }

    // A light presence frame carries no news about the lock streak, so it must report the streak
    // unchanged rather than report none. Reporting zero made the viewfinder oscillate
    // "1 of 3" → "0 of 3" → "2 of 3" at ~80ms intervals, which on device read as the counter
    // sprinting 1→3 in a quarter second (Tomas, iPad, 2026-07-27).
    func testLightFramesReportTheStreakRatherThanZeroingIt() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let narrowing = CountingNarrowing(poolIds: ["card_a"])
        // throttle 4 → frames 1-3 are light presence frames, frame 4 is the heavy one.
        let pipeline = try makePipeline(narrowing: narrowing, fingerThrottle: 4)
        var heavy: FrameOutcome?
        for _ in 0..<4 { heavy = await pipeline.process(pb) }
        let confirmed = try XCTUnwrap(heavy).confirmations
        XCTAssertGreaterThan(confirmed, 0, "precondition: the heavy frame must start a streak")

        let light = await pipeline.process(pb)          // frame 5 — light again
        XCTAssertEqual(light.confirmations, confirmed,
                       "a light frame must not zero the streak the viewfinder is showing")
        XCTAssertEqual(light.poolCount, try XCTUnwrap(heavy).poolCount,
                       "nor drop the pool size back to 'Reading the card…'")
    }

    private func makePipeline(narrowing: CandidateNarrowing,
                              fingerThrottle: Int = 1) throws -> ScanPipeline {
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))
        let index = try CandidateIndex(store: try FixtureCatalog.make())
        // fingerThrottle 1 → every frame is heavy, so the count is frames-in = OCR-considered.
        // minFocus 0 → the fixture plate must not be quality-gated out before the text stages.
        return ScanPipeline(detector: CardDetector(), textGate: TextGate(index: index),
                            matcher: matcher, narrowing: narrowing,
                            fingerThrottle: fingerThrottle, minFocus: 0)
    }

    // The reuse itself: a steady card is OCR'd ONCE across the frames of one acquisition. Three
    // identical plates cost one text read, not three — the change that took an iPad heavy frame
    // from ~4,300ms to ~1,400ms for every frame after the first (2026-07-27).
    func testSteadyCardOcrsOncePerAcquisition() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let narrowing = CountingNarrowing(poolIds: ["card_a"])
        let pipeline = try makePipeline(narrowing: narrowing)
        for _ in 0..<3 { _ = await pipeline.process(pb) }
        XCTAssertEqual(narrowing.calls, 1, "the same plate must not be re-OCR'd each frame")
    }

    // Reset drops the cached read: the user's escape hatch has to mean the scanner looks again
    // with no memory, and a retained pool is memory.
    func testResetForcesAFreshRead() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let narrowing = CountingNarrowing(poolIds: ["card_a"])
        let pipeline = try makePipeline(narrowing: narrowing)
        _ = await pipeline.process(pb)
        await pipeline.reset()
        _ = await pipeline.process(pb)
        XCTAssertEqual(narrowing.calls, 2, "reset must invalidate the cached OCR/pool")
    }

    // The binder-swap guard, and the reason reuse is safe without a no-card gap: a pool that does
    // not contain the card in front of the camera cannot produce a strong match, so the cache is
    // dropped every frame instead of silently narrowing for a card that has already been replaced.
    // Here the plate is card_a while the pool only offers card_b — inliers stay under the lock
    // floor, so every frame must re-read rather than reuse.
    func testPoolThatDoesNotExplainThePlateIsNotReused() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let narrowing = CountingNarrowing(poolIds: ["card_b"])
        let pipeline = try makePipeline(narrowing: narrowing)
        for _ in 0..<3 { _ = await pipeline.process(pb) }
        XCTAssertEqual(narrowing.calls, 3, "a stale/wrong pool must never be reused")
    }

    func testLockAppendsDraftToStagingNotCollection() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))

        let catalog = try FixtureCatalog.make()
        let staging = ScanStagingStore.inMemory()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: StubNarrowing(), staging: staging,
                              store: catalog, fingerThrottle: 1)
        await model.run(source: ReplaySource(buffer: pb, count: 6))

        XCTAssertFalse(staging.drafts.isEmpty, "a confident lock should stage a draft")
        XCTAssertNotNil(staging.drafts.first?.condition) // defaulted (NM)
    }

    /// A capture is staged at the chosen condition, not at a hardcoded NM — and it's priced at
    /// that condition, so the tray's running total can't quote mint money for a played stack.
    func testStagedDraftUsesTheChosenConditionAndPricesAtIt() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))

        let catalog = try FixtureCatalog.make()
        let staging = ScanStagingStore.inMemory()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: StubNarrowing(),
                              staging: staging, store: catalog, fingerThrottle: 1)
        model.stagingCondition = .mp
        await model.run(source: ReplaySource(buffer: pb, count: 6))

        let draft = try XCTUnwrap(staging.drafts.first)
        XCTAssertEqual(draft.condition, .mp, "the draft must carry the chosen condition")
        // Whatever the fixture prices this at, it must agree with the shared resolver asked the
        // same question — the point is that condition reaches the price, not a specific figure.
        let expected = GroupStats.unitPrice(
            condition: .mp, variant: draft.variant,
            price: try? catalog.price(cardId: draft.cardId),
            variants: (try? catalog.variantPrices(cardId: draft.cardId)) ?? [],
            conditions: (try? catalog.conditionPrices(cardId: draft.cardId)) ?? [],
            matrix: (try? catalog.matrixPrices(cardId: draft.cardId)) ?? [])
        XCTAssertEqual(draft.priceUsdSnapshot, expected)
    }

    /// The choice outlives the model, because the stack in your hands outlives one launch.
    func testStagingConditionPersists() async throws {
        XCTAssertEqual(AppConfig.scanCondition, .nm)
        let catalog = try FixtureCatalog.make()
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: try Matcher(store: store, codebook: try Codebook.bundled(in: bundle())),
                              detector: CardDetector(), textGate: TextGate(index: index),
                              narrowing: StubNarrowing(), staging: .inMemory(), store: catalog)
        model.stagingCondition = .lp
        XCTAssertEqual(AppConfig.scanCondition, .lp)
        XCTAssertEqual(model.stagingCondition, .lp)
    }

    func testStagedDraftsAreNotOwnedUntilCommitted() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))

        let catalog = try FixtureCatalog.make()
        let repo = InMemoryCollectionRepository()
        let collection = CollectionModel(repository: repo, store: catalog)
        let staging = ScanStagingStore.inMemory()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: StubNarrowing(), staging: staging,
                              store: catalog, fingerThrottle: 1)
        await model.run(source: ReplaySource(buffer: pb, count: 6))

        // The taste signal is collection.entries.map(\.cardId) — staged drafts must be absent.
        XCTAssertFalse(staging.drafts.isEmpty)
        XCTAssertTrue(repo.entries.isEmpty, "staged scans must NOT be owned before commit")

        // Commit one and verify it becomes owned. XCTUnwrap, not `[0]`: an empty tray here is a
        // legitimate test failure, and subscripting turned it into a process-killing fatal that
        // took the other ~460 tests down with it.
        let ok = await collection.commitScan(try XCTUnwrap(staging.drafts.first), to: .tin)
        XCTAssertTrue(ok)
        XCTAssertEqual(repo.entries.count, 1)
    }

    /// Wrong-lock guard: a visual winner with a twin-in-pool must be routed to the ambiguous
    /// chooser, never auto-locked and staged. This is the discriminating test the F1b review
    /// finding asked for — the two tests above use StubNarrowing (hasTwinInPool: false), which
    /// still passes even if the pipeline forgets to compute+thread the consistency map at all
    /// (ScanSession falls back to visual-only lock when `consistency` is nil). Only a twin-in-
    /// pool assertion proves the map is genuinely threaded end-to-end.
    // Once a chooser is on screen, NO frame event may clear it — only a user tap. The pipeline's
    // quality-gate `.guide` is emitted WITHOUT going through ScanSession (so the session's
    // chooserPending latch never sees it); it was wiping the chooser after a few blurry frames
    // ("the 4 options went away after 3-5s"). Regression: handle must ignore stray guide/lock
    // while options are up, and only dismissChooser / chooseAmbiguous clears them.
    func testChooserIsModalAgainstStrayFrameEvents() async throws {
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))
        let catalog = try FixtureCatalog.make()
        let staging = ScanStagingStore.inMemory()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: StubNarrowing(), staging: staging,
                              store: catalog, fingerThrottle: 1)

        // Put a chooser on screen (the first .ambiguous is allowed — ambiguous is empty here).
        await model.handle(.ambiguous(["card_a"]))
        XCTAssertEqual(model.ambiguous.map(\.id), ["card_a"])

        // A quality-gate guide (the pipeline-bypass path) must NOT wipe the chooser…
        await model.handle(.guide(bestGuess: nil))
        XCTAssertEqual(model.ambiguous.map(\.id), ["card_a"], "a stray .guide must not dismiss the chooser")
        // …nor may a stray lock stage a draft or clear it.
        await model.handle(.lock(cardId: "card_a"))
        XCTAssertEqual(model.ambiguous.map(\.id), ["card_a"], "a stray .lock must not dismiss the chooser")
        XCTAssertTrue(staging.drafts.isEmpty, "nothing may stage while the chooser is up")

        // Only a user action resolves it.
        await model.dismissChooser()
        XCTAssertTrue(model.ambiguous.isEmpty)
    }

    func testTwinInPoolRoutesToChooserNotLock() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))

        let catalog = try FixtureCatalog.make()
        let staging = ScanStagingStore.inMemory()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: TwinStub(), staging: staging,
                              store: catalog, fingerThrottle: 1)
        await model.run(source: ReplaySource(buffer: pb, count: 6))

        XCTAssertTrue(staging.drafts.isEmpty,
            "a visual winner with a twin in the pool must route to the chooser, not auto-lock")
        // Variant A chooser data: options carry resolved metadata, never bare id codes only.
        XCTAssertEqual(model.ambiguous.first?.id, "card_a")
        XCTAssertEqual(model.guidance, "Scanning paused — pick your card")
    }

    /// Look-up mode answers "what is this?" without touching the tin: a lock publishes the card
    /// for the view to present and stages nothing, so asking about a card you're not buying no
    /// longer costs a stage-then-delete round trip.
    func testLookUpModePublishesCardWithoutStaging() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))

        let catalog = try FixtureCatalog.make()
        let staging = ScanStagingStore.inMemory()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: StubNarrowing(),
                              staging: staging, store: catalog, fingerThrottle: 1)
        // The mode persists through AppConfig, so restore it rather than leaking a `true`
        // default into every later test that expects a lock to stage.
        let previous = AppConfig.scanLookUpMode
        defer { AppConfig.scanLookUpMode = previous }
        model.isLookUpMode = true

        await model.run(source: ReplaySource(buffer: pb, count: 6))

        XCTAssertEqual(model.lookedUpCardId, "card_a", "a lock should publish the card")
        XCTAssertTrue(staging.drafts.isEmpty, "look-up mode must never stage a draft")
    }

    /// The chooser path funnels through the same `stage`, so picking a card in look-up mode must
    /// look it up too — not quietly add it.
    func testLookUpModeAppliesToTheAmbiguityChooserToo() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))

        let catalog = try FixtureCatalog.make()
        let staging = ScanStagingStore.inMemory()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: StubNarrowing(),
                              staging: staging, store: catalog, fingerThrottle: 1)
        let previous = AppConfig.scanLookUpMode
        defer { AppConfig.scanLookUpMode = previous }
        model.isLookUpMode = true

        await model.chooseAmbiguous(cardId: "card_a")

        XCTAssertEqual(model.lookedUpCardId, "card_a")
        XCTAssertTrue(staging.drafts.isEmpty)
    }

    /// A presented look-up card is modal: the camera is still running underneath, and a second
    /// lock landing while the sheet is up would swap the card out from under the user.
    func testPresentedLookUpCardFreezesFurtherLocks() async throws {
        let catalog = try FixtureCatalog.make()
        let staging = ScanStagingStore.inMemory()
        let index = try CandidateIndex(store: catalog)
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: StubNarrowing(),
                              staging: staging, store: catalog, fingerThrottle: 1)
        let previous = AppConfig.scanLookUpMode
        defer { AppConfig.scanLookUpMode = previous }
        model.isLookUpMode = true

        await model.handle(.lock(cardId: "card_a"))
        XCTAssertEqual(model.lookedUpCardId, "card_a")

        await model.handle(.lock(cardId: "card_b"))
        XCTAssertEqual(model.lookedUpCardId, "card_a", "a second lock must not swap the shown card")

        // Dismissing clears it and reopens the scanner to the next card.
        await model.clearLookedUpCard()
        XCTAssertNil(model.lookedUpCardId)
        await model.handle(.lock(cardId: "card_b"))
        XCTAssertEqual(model.lookedUpCardId, "card_b")
    }

    /// Freezing the EVENT was never enough: the cascade behind it still ran, so every second
    /// spent reading a looked-up card was a second of OCR + ORB + RANSAC whose result `handle`
    /// discards on arrival. In look-up mode — scan, read, dismiss, repeat — that is most of a
    /// session, and it is why the phone gets hot.
    func testPresentedLookUpCardStopsTheCascadeNotJustItsEvent() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))
        let catalog = try FixtureCatalog.make()
        let narrowing = CountingNarrowing(poolIds: ["card_a"])
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: try CandidateIndex(store: catalog)),
                              narrowing: narrowing, staging: ScanStagingStore.inMemory(),
                              store: catalog, fingerThrottle: 1)
        model.lookedUpCardId = "card_a"          // a card is on screen

        let source = ThrottleSpySource(buffer: pb, count: 6)
        await model.run(source: source)

        XCTAssertEqual(narrowing.calls, 0, "no frame may be OCR'd while its result is pre-discarded")
        XCTAssertEqual(source.idleStates, Array(repeating: true, count: 6),
                       "and the camera must sit at its idle rate for as long as the sheet is up")
    }

    /// The interaction between #154 and #155, which merged clean and were each correct alone.
    ///
    /// A borrowed viewfinder (the trade picker) sets `lookedUpCardId` as a HANDOFF: `onChange`
    /// gives the card to the caller and clears it, and nothing is ever presented over the camera.
    /// Throttling on "a card was recognised" instead of "something is on screen" idled the camera
    /// on every card — and because the waking frame then arrives at the *idle* rate, that is up to
    /// half a second of dead viewfinder per card, in the one flow built for working through a pile
    /// without pause. Both PRs' own tests pass either way; only the pair is wrong.
    func testABorrowedViewfinderKeepsScanningWhileHandingOffEachCard() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))
        let catalog = try FixtureCatalog.make()
        let narrowing = CountingNarrowing(poolIds: ["card_a"])
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: try CandidateIndex(store: catalog)),
                              narrowing: narrowing, staging: ScanStagingStore.inMemory(),
                              store: catalog, fingerThrottle: 1)
        model.forcesLookUp = true                // the trade picker owns this viewfinder
        model.lookedUpCardId = "card_a"          // mid-handoff, NOT presented

        let source = ThrottleSpySource(buffer: pb, count: 6)
        await model.run(source: source)

        XCTAssertFalse(model.isModalPresented, "a handoff is not a presentation")
        XCTAssertFalse(source.idleStates.contains(true),
                       "the camera must never idle mid-handoff — the next card is already coming")
        XCTAssertGreaterThan(narrowing.calls, 0, "and the cascade has to keep running to read it")

        // The chooser is the case that IS on screen in both worlds, borrowed or not.
        model.ambiguous = [ChooserOption(id: "card_a", card: nil, setName: "S",
                                         year: nil, setTotal: nil)]
        XCTAssertTrue(model.isModalPresented, "a chooser is really presented, borrowed or not")
    }

    /// The hot-phone case: the scanner left open and face-up on a table between stacks. Nothing
    /// to look at, and at the capture default a segmentation network running against a tabletop
    /// ~22 times a second for as long as it takes to get the next cards ready.
    func testCameraIdlesOnAnEmptyViewfinderAndWakesOnACard() {
        var throttle = CameraThrottle()
        XCTAssertFalse(throttle.update(cardVisible: true, modal: false),
                       "a card in view scans at the full rate")
        for _ in 0..<(CameraThrottle.emptyFramesBeforeIdle - 1) {
            XCTAssertFalse(throttle.update(cardVisible: false, modal: false),
                           "a dropout shorter than the threshold must not throttle a live scan")
        }
        XCTAssertTrue(throttle.update(cardVisible: false, modal: false), "an empty viewfinder idles")
        XCTAssertFalse(throttle.update(cardVisible: true, modal: false), "and the next card wakes it")
    }

    /// A hand-held card already flickers out of the detector for runs of frames — that is what
    /// `graceMisses` exists to absorb. Idle at or below it and the camera would throttle itself
    /// in the middle of a scan that is going fine.
    func testIdleThresholdClearsTheLockGatesDropoutGrace() {
        XCTAssertGreaterThan(CameraThrottle.emptyFramesBeforeIdle, LockConfig().graceMisses)
    }

    /// Dismissing a sheet has to restore the scanning rate on the next frame, and the next card
    /// is usually NOT in frame yet when it does. Letting the empty count run during the sheet
    /// would leave the camera idling into the next scan, costing it the wake-up it just earned.
    func testAModalSheetIdlesTheCameraAndReleasesItOnTheNextFrame() {
        var throttle = CameraThrottle()
        for _ in 0..<(CameraThrottle.emptyFramesBeforeIdle + 5) {
            XCTAssertTrue(throttle.update(cardVisible: false, modal: true), "a sheet idles at once")
        }
        XCTAssertFalse(throttle.update(cardVisible: false, modal: false),
                       "dismissing returns to the scanning rate immediately, empty viewfinder or not")
    }

    /// The source is captured ONTO the draft at scan time, not read from the model at commit.
    /// Drafts persist to disk and survive relaunch; the picker deliberately does not — read it
    /// at commit and a pack scanned last night commits untagged.

    /// A scanner that is working must SAY so. Silence is indistinguishable from a dead scanner,
    /// which is exactly how an iPad reads while an A10 grinds through ORB matching (2026-07-27):
    /// the viewfinder showed nothing for seconds and the user concluded it was broken.
    func testExaminingAFrameReportsWhatTheScannerIsDoing() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))

        let catalog = try FixtureCatalog.make()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: StubNarrowing(),
                              staging: ScanStagingStore.inMemory(), store: catalog,
                              fingerThrottle: 1)

        XCTAssertFalse(model.isExamining, "a scanner that hasn't seen a frame isn't examining")
        XCTAssertEqual(model.activityText, ScanModel.idleGuidance,
                       "and it falls back to the framing hint rather than saying nothing at all")

        await model.run(source: ReplaySource(buffer: pb, count: 6))

        XCTAssertTrue(model.isExamining, "frames arrived, so the spinner must have something to turn on")
        XCTAssertNotEqual(model.activityText, ScanModel.idleGuidance,
                          "while examining, the viewfinder names the work instead of the framing hint")
    }

    /// The complaint this exists for (Tomas, iPad, 2026-07-27): "seemingly cycling through the
    /// same thing… the same messaging from the app even though it is doing much better." Every
    /// frame of the confirmation streak rendered as one unchanging "Hold steady", so a lock gate
    /// working through three frames was indistinguishable from a scanner going in circles. On an
    /// A10 that streak is ~5s of identical text.
    func testEachConfirmingFrameReadsDifferently() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))
        let catalog = try FixtureCatalog.make()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: StubNarrowing(),
                              staging: ScanStagingStore.inMemory(), store: catalog,
                              fingerThrottle: 1)

        await model.run(source: ReplaySource(buffer: pb, count: 1))
        let first = model.activityText
        let firstProgress = model.lockProgress
        await model.run(source: ReplaySource(buffer: pb, count: 1))

        XCTAssertNotEqual(first, model.activityText,
                          "two confirming frames must not render the same message")
        XCTAssertGreaterThan(model.lockProgress, firstProgress,
                             "and the ring must advance, not sit still")
        XCTAssertTrue(model.activityText.contains("2 of \(model.confirmationsNeeded)"),
                      "the streak is counted out loud: \(model.activityText)")
    }

    /// `stage()` has always set `guidance` to "Added <name> — next card", but `activityText` only
    /// consulted `guidance` while a chooser was up and `bestGuess` survived the lock — so the one
    /// message the user is actually waiting for fell through to "Hold steady" and was never shown.
    func testCaptureIsAnnouncedInTheViewfinder() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))
        let catalog = try FixtureCatalog.make()
        let staging = ScanStagingStore.inMemory()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: StubNarrowing(),
                              staging: staging, store: catalog, fingerThrottle: 1)

        await model.run(source: ReplaySource(buffer: pb, count: 6))

        XCTAssertFalse(staging.drafts.isEmpty, "precondition: this run has to actually lock")
        XCTAssertTrue(model.activityText.hasPrefix("Added "),
                      "a capture must be announced, got: \(model.activityText)")
    }

    func testStagedDraftCapturesTheChosenSource() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))

        let catalog = try FixtureCatalog.make()
        let staging = ScanStagingStore.inMemory()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: StubNarrowing(),
                              staging: staging, store: catalog, fingerThrottle: 1)
        model.stagingVia = .pulled
        await model.run(source: ReplaySource(buffer: pb, count: 6))

        let draft = try XCTUnwrap(staging.drafts.first)
        XCTAssertEqual(draft.acquiredVia, .pulled)
    }

    /// A fresh scanner makes no claim about where cards came from.
    func testScannerStartsWithNoSourceClaim() async throws {
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))
        let catalog = try FixtureCatalog.make()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: StubNarrowing(),
                              staging: ScanStagingStore.inMemory(), store: catalog)
        XCTAssertNil(model.stagingVia)
    }

    // MARK: Borrowing the scanner

    /// A trade reads a stranger's card onto the table. Staging it would file someone else's
    /// property into your tin, so the caller pins look-up — and the lock must obey the pin even
    /// though the user's own mode says Add.
    func testForcedLookUpStagesNothingEvenWhenTheUsersModeIsAdd() async throws {
        let pb = try TestPixelBuffer.canonicalCardA(bundle: bundle())
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle()))

        let catalog = try FixtureCatalog.make()
        let staging = ScanStagingStore.inMemory()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: matcher, detector: CardDetector(),
                              textGate: TextGate(index: index), narrowing: StubNarrowing(),
                              staging: staging, store: catalog, fingerThrottle: 1)
        let previous = AppConfig.scanLookUpMode
        defer { AppConfig.scanLookUpMode = previous }
        AppConfig.scanLookUpMode = false
        model.isLookUpMode = false
        model.forcesLookUp = true

        await model.run(source: ReplaySource(buffer: pb, count: 6))

        XCTAssertEqual(model.lookedUpCardId, "card_a", "the caller still needs the card")
        XCTAssertTrue(staging.drafts.isEmpty, "a borrowed viewfinder must never stage")
    }

    /// Borrowing must not rewrite the Scan tab's sticky mode. Setting `isLookUpMode` would have
    /// been the one-line version and it persists — so a single trade would silently leave the
    /// scanner in Look up the next time the user opened it to catalogue a box.
    func testForcingLookUpLeavesTheUsersPersistedModeAlone() throws {
        // No frames needed: this is about the two flags, not about what a lock does with them.
        let store = try FingerprintTestSupport.openFixtureStore(bundle: bundle())
        defer { try? store.close() }
        let catalog = try FixtureCatalog.make()
        let index = try CandidateIndex(store: catalog)
        let model = ScanModel(matcher: try Matcher(store: store, codebook: try Codebook.bundled(in: bundle())),
                              detector: CardDetector(), textGate: TextGate(index: index),
                              narrowing: StubNarrowing(), staging: .inMemory(), store: catalog)
        let previous = AppConfig.scanLookUpMode
        defer { AppConfig.scanLookUpMode = previous }
        AppConfig.scanLookUpMode = false
        model.isLookUpMode = false

        model.forcesLookUp = true
        XCTAssertTrue(model.isLookingUp, "the pipeline follows the pin")
        XCTAssertFalse(model.isLookUpMode, "the picker still shows the user's own choice")
        XCTAssertFalse(AppConfig.scanLookUpMode, "and nothing was written to their preference")

        model.forcesLookUp = false
        XCTAssertFalse(model.isLookingUp, "handing the scanner back restores Add mode")
    }
}
