import XCTest
import CoreVideo
@testable import TheTin

@MainActor
final class ScanModelTests: XCTestCase {
    private func bundle() -> Bundle { Bundle(for: Self.self) }

    private struct ReplaySource: FrameSource {
        let buffer: CVPixelBuffer; let count: Int
        func stream() -> AsyncStream<CVPixelBuffer> {
            AsyncStream { cont in for _ in 0..<count { cont.yield(buffer) }; cont.finish() }
        }
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

        // Commit one and verify it becomes owned.
        let ok = await collection.commitScan(staging.drafts[0], to: .tin)
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
}
