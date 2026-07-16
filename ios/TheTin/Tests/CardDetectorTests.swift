import XCTest
import CoreImage
import Vision
@testable import TheTin

/// Covers `OrientationNormalizer` (used by `CardDetector.detect`'s doc-seg/rectangles path)
/// in isolation. The full doc-segmentation → rectify path is NOT exercised here: the only
/// in-bundle card asset (`card_a.pngdata`) is a tight borderless crop, and rendering it to
/// the canonical 660x920 plate drives `CardDetector`'s `canonicalPassthrough` branch instead
/// of doc-seg (see CardDetector.swift). See task-D1-brief.md's "Testability decision".
final class CardDetectorTests: XCTestCase {
    private func bundle() -> Bundle { Bundle(for: Self.self) }

    private func loadCardImage() throws -> CIImage {
        let url = try XCTUnwrap(bundle().url(forResource: "card_a", withExtension: "pngdata"))
        return try XCTUnwrap(CIImage(data: try Data(contentsOf: url)))
    }

    /// Full-plate `.accurate` OCR text, used only as a ground-truth-free equality check
    /// between two orientation outcomes (not as production logic).
    private func accurateOCRText(_ ci: CIImage, context: CIContext) -> String {
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    func testOrientUprightResolvesA180DegreeFlip() throws {
        let context = CIContext()
        let upright = try loadCardImage()
        let rotated180 = OrientationNormalizer.rotate(upright, degrees: 180)

        let correctedFromUpright = try XCTUnwrap(
            OrientationNormalizer.orientUpright(upright, context: context))
        let correctedFromRotated = try XCTUnwrap(
            OrientationNormalizer.orientUpright(rotated180, context: context))

        let textFromUpright = accurateOCRText(correctedFromUpright, context: context)
        let textFromRotated = accurateOCRText(correctedFromRotated, context: context)
        XCTAssertFalse(textFromUpright.isEmpty, "expected OCR text on the upright plate")
        XCTAssertEqual(textFromUpright, textFromRotated,
                       "orientUpright should resolve a 180° flip to the same reading as the upright source")

        // And prove orientUpright actually did something: its chosen output must score higher
        // than the deliberately-upside-down raw rotated input.
        let rotatedRawCG = try XCTUnwrap(context.createCGImage(rotated180, from: rotated180.extent))
        let correctedCG = try XCTUnwrap(context.createCGImage(correctedFromRotated, from: correctedFromRotated.extent))
        XCTAssertGreaterThan(OrientationNormalizer.uprightScore(correctedCG),
                             OrientationNormalizer.uprightScore(rotatedRawCG),
                             "orientUpright's chosen rotation should read better than the upside-down raw input")
    }

    func testOrientUprightScalesToCanonicalDimensions() throws {
        let context = CIContext()
        let upright = try loadCardImage()
        let oriented = try XCTUnwrap(OrientationNormalizer.orientUpright(upright, context: context))
        XCTAssertEqual(oriented.extent.width, CGFloat(kFPCanonW), accuracy: 0.5)
        XCTAssertEqual(oriented.extent.height, CGFloat(kFPCanonH), accuracy: 0.5)
    }

    /// Light-frame presence check: canonical test buffers short-circuit true (passthrough
    /// parity); an arbitrary non-canonical buffer must answer without crashing (doc-seg's
    /// permissiveness means we can't assert false on a synthetic blank — see detect()'s
    /// size-first passthrough doc).
    func testCardPresentCanonicalShortCircuit() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(kFPCanonW), Int(kFPCanonH),
                            kCVPixelFormatType_32BGRA, nil, &pb)
        XCTAssertTrue(CardDetector().cardPresent(pixelBuffer: try XCTUnwrap(pb)))

        var live: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 1080, 1920, kCVPixelFormatType_32BGRA, nil, &live)
        _ = CardDetector().cardPresent(pixelBuffer: try XCTUnwrap(live))   // must not crash
    }
}
