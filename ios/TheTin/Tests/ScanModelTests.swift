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
}
