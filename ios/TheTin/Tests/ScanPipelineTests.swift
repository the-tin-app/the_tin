import XCTest
import CoreVideo
@testable import TheTin

final class ScanPipelineTests: XCTestCase {
    // Build a distinct 660x920 BGRA CVPixelBuffer filled with a constant byte value.
    private func filledBuffer(_ value: UInt8) throws -> CVPixelBuffer {
        let w = 660, h = 920
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true]
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buf = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!
        let stride = CVPixelBufferGetBytesPerRow(buf)
        memset(base, Int32(value), stride * h)
        return buf
    }

    // The pipeline must fingerprint EACH frame's own pixels — never a cross-frame blend.
    func testFingerprintsSingleFramePixelsNotAFusion() async throws {
        let store = try FingerprintTestSupport.openFixtureStore(bundle: Bundle(for: Self.self))
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: Bundle(for: Self.self)))
        let catalog = try FixtureCatalog.make()
        let textGate = TextGate(index: try CandidateIndex(store: catalog))

        var seenFirstBytes: [UInt8] = []
        let pipeline = ScanPipeline(
            detector: CardDetector(), textGate: textGate, matcher: matcher,
            narrowing: try CandidateIndex(store: catalog), fingerThrottle: 1,
            minFocus: 0, maxGlare: 1,
            fingerprint: { data, _, _, _ in
                seenFirstBytes.append(data.first ?? 0)   // record which frame's pixels arrived
                return CardFingerprint(keypoints: [], descriptors: Data())
            })

        for v: UInt8 in [10, 20, 30] {
            _ = await pipeline.process(try filledBuffer(v))
        }
        // Each call saw exactly one uniform frame — the constant byte of that frame.
        XCTAssertEqual(seenFirstBytes, [10, 20, 30])
    }

    // A quality-gated (blurry/glared) frame must still surface an event — a silently swallowed
    // frame leaves the guidance stuck on the initial "Frame the card inside the box" even though
    // a card IS detected (how the 2026-07-15 binder failure stayed invisible on device).
    func testQualityGateRejectionEmitsGuideEvent() async throws {
        let store = try FingerprintTestSupport.openFixtureStore(bundle: Bundle(for: Self.self))
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: Bundle(for: Self.self)))
        let catalog = try FixtureCatalog.make()
        let textGate = TextGate(index: try CandidateIndex(store: catalog))

        let pipeline = ScanPipeline(
            detector: CardDetector(), textGate: textGate, matcher: matcher,
            narrowing: try CandidateIndex(store: catalog), fingerThrottle: 1,
            minFocus: .greatestFiniteMagnitude, maxGlare: 1,   // gate rejects every plate
            fingerprint: { _, _, _, _ in
                XCTFail("gated frame must never be fingerprinted")
                return nil
            })

        let out = await pipeline.process(try filledBuffer(128))
        XCTAssertFalse(out.noCard, "a detected-but-gated frame is not a no-card frame")
        XCTAssertEqual(out.event, .guide(bestGuess: nil),
                       "gate rejection must surface a guide event, not silence")
    }
}
