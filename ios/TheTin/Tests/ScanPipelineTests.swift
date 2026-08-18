import XCTest
import CoreVideo
import UIKit
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

    /// A 660x920 BGRA buffer with a solid border and an inset "art" window — the pipeline's
    /// canonical passthrough hands this straight through as the plate, so the centring meter
    /// sees exactly these widths.
    private func borderedBuffer(left: Int, right: Int, top: Int, bottom: Int) throws -> CVPixelBuffer {
        let w = 660, h = 920
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true]
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buf = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * stride + x * 4
                let inArt = x >= left && x < w - right && y >= top && y < h - bottom
                base[i] = inArt ? 90 : 0
                base[i + 1] = inArt ? 60 : 220
                base[i + 2] = inArt ? 40 : 255
                base[i + 3] = 255
            }
        }
        return buf
    }

    private func centeringPipeline() throws -> ScanPipeline {
        let store = try FingerprintTestSupport.openFixtureStore(bundle: Bundle(for: Self.self))
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: Bundle(for: Self.self)))
        let catalog = try FixtureCatalog.make()
        return ScanPipeline(
            detector: CardDetector(), textGate: TextGate(index: try CandidateIndex(store: catalog)),
            matcher: matcher, narrowing: try CandidateIndex(store: catalog), fingerThrottle: 1,
            minFocus: 0, maxGlare: 1,
            fingerprint: { _, _, _, _ in CardFingerprint(keypoints: [], descriptors: Data()) })
    }

    /// The editor's picture is rendered ONLY on the frame that locks. It costs a second
    /// perspective-correct and a full-size render, and frames outnumber locks by hundreds to one —
    /// paying it per frame would be a real cost on an A10 for a picture almost always thrown away.
    func testNoEditorPictureWithoutALock() async throws {
        let pipeline = try centeringPipeline()
        // The stubbed fingerprint matches nothing, so this frame is examined but never locks.
        _ = await pipeline.process(try borderedBuffer(left: 40, right: 20, top: 30, bottom: 60))
        let plate = await pipeline.currentPlate()
        XCTAssertNil(plate, "an examined-but-unlocked frame must not pay for the editor picture")
    }

    /// The margin is what makes the outer lines placeable: the card's cut edge has to be visible
    /// and reachable, not pinned against the boundary of the picture. Without it the whole
    /// eight-line correction is impossible, so the crop being wider than the quad is the property
    /// worth pinning.
    func testTheEditorPictureIsCroppedWiderThanTheCard() throws {
        let side = 800, cardFrom = 200, cardTo = 600
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, nil, &pb)
        let buf = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<side {
            for x in 0..<side {
                let i = y * stride + x * 4
                let onCard = (cardFrom..<cardTo).contains(x) && (cardFrom..<cardTo).contains(y)
                base[i] = onCard ? 0 : 200; base[i + 1] = onCard ? 0 : 200
                base[i + 2] = onCard ? 255 : 200; base[i + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])

        // A square quad on the card, so the y-flip between buffer rows and CI space is immaterial.
        let f = CGFloat(cardFrom), t = CGFloat(cardTo)
        let quad = CardQuad(topLeft: CGPoint(x: f, y: t), topRight: CGPoint(x: t, y: t),
                            bottomLeft: CGPoint(x: f, y: f), bottomRight: CGPoint(x: t, y: f))
        let jpeg = try XCTUnwrap(EditorPlate.jpeg(pixelBuffer: buf, quad: quad, degrees: 0,
                                                  context: CIContext()))
        let image = try XCTUnwrap(UIImage(data: jpeg))

        let cardSide = CGFloat(cardTo - cardFrom)
        XCTAssertEqual(image.size.width, cardSide * EditorPlate.margin, accuracy: 2,
                       "the picture must be the card plus a margin on each side")
        XCTAssertEqual(image.size.height, cardSide * EditorPlate.margin, accuracy: 2)
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
