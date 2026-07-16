import XCTest
import CoreImage
import CoreVideo
@testable import TheTin

/// Regression gates for the DETECTION layer (doc-seg + guide-constrained quad selection on
/// full-frame detection + center-ranked quad + orientation) — the layer LabeledPhotoAccuracyTests
/// bypasses via canonicalPassthrough.
/// Fixtures built by fingerprint/scripts/make_detection_fixtures.py.
final class DetectionAccuracyTests: XCTestCase {
    private static let ciContext = CIContext()

    /// A 9-pocket binder page must resolve to the AIMED (center) card, not the whole page.
    /// Without the ScanGuide crop, doc-seg returns a whole-page quad at conf 0.99 and the
    /// plate is a nine-card montage (reproduced 2026-07-15).
    func testBinderMontageResolvesToCenterCard() throws {
        let ids = ["hgss3-39", "ex6-58", "ex8-63", "ex10-54", "bw8-103",
                   "pl4-34", "ex6-115", "me03-116", "swsh7-49"]
        let results = try Self.detectAndMatch(fixture: "binder-montage", candidateIds: ids)
        XCTAssertEqual(results.first?.cardId, "hgss3-39",
                       "center card must win — got \(results.prefix(3))")
        XCTAssertGreaterThanOrEqual(results.first?.inliers ?? 0, 50)
        let runnerUp = results.dropFirst().first?.inliers ?? 0
        XCTAssertGreaterThanOrEqual(Double(results.first?.inliers ?? 0), 2.0 * Double(max(runnerUp, 1)),
                                    "center card must dominate the neighbors")
    }

    /// Full live-resolution photos through the REAL detection path end-to-end.
    func testFullFrameSingleCardDetection() throws {
        for (fixture, truth) in [("fullframe-1535", "ex6-58"),
                                 ("fullframe-1557", "me03-116"),
                                 ("fullframe-1577", "swsh7-49")] {
            try autoreleasepool {
                let results = try Self.detectAndMatch(fixture: fixture,
                                                      candidateIds: [truth, "hgss3-39", "bw8-103"])
                XCTAssertEqual(results.first?.cardId, truth, "\(fixture): wrong winner")
                XCTAssertGreaterThanOrEqual(results.first?.inliers ?? 0, 30, "\(fixture): weak match")
            }
        }
    }

    /// A real binder pocket with the card's long axis PERPENDICULAR to the guide window's —
    /// the posture of standing over a flat binder (2026-07-15 on-device failure, 7/9 cards).
    /// Regression-gates the orientation-neutral guide FITS check + the minimum-size guard:
    /// with the naive w/h check the sideways card quad is rejected and a 435×309 glare
    /// fragment "passes the guide" instead → zoomed garbage plate (focus ≈ 4) → silently
    /// eaten by the minFocus gate. Truth: Mega Clefable me03-031 (labels: IMG_1629, binder).
    func testBinderPocketSidewaysCard() throws {
        let results = try Self.detectAndMatch(fixture: "fullframe-1629",
                                              candidateIds: ["me03-031", "hgss3-39", "bw8-103"])
        XCTAssertEqual(results.first?.cardId, "me03-031", "sideways binder card: wrong winner")
        XCTAssertGreaterThanOrEqual(results.first?.inliers ?? 0, 30, "sideways binder card: weak match")
    }

    /// PNG fixture → native-size BGRA CVPixelBuffer → real CardDetector.detect (guide-constrained
    /// quad selection on full-frame detection, doc-seg, orientation — NO passthrough: fixtures
    /// are never 660×920) → fingerprint → matchRanked.
    private static func detectAndMatch(fixture: String, candidateIds: [String]) throws -> [MatchCandidate] {
        let bundle = Bundle(for: DetectionAccuracyTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: fixture, withExtension: "pngdata"))
        let ci = try XCTUnwrap(CIImage(data: Data(contentsOf: url)))
        let w = Int(ci.extent.width), h = Int(ci.extent.height)
        XCTAssertFalse(w == Int(kFPCanonW) && h == Int(kFPCanonH), "fixture must not passthrough")
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        let buffer = try XCTUnwrap(pb)
        ciContext.render(ci, to: buffer)
        let frame = try XCTUnwrap(CardDetector().detect(pixelBuffer: buffer),
                                  "\(fixture): detector returned nil")
        let query = try XCTUnwrap(ScanFingerprinter.fingerprint(
            pixels: frame.pixels, width: frame.width, height: frame.height,
            bytesPerRow: frame.bytesPerRow))
        let packURL = try XCTUnwrap(bundle.url(forResource: "labeled-pack", withExtension: "sqlite"))
        let store = try FingerprintStore(path: packURL.path)
        defer { try? store.close() }
        let matcher = try Matcher(store: store, codebook: try Codebook.bundled(in: bundle))
        return try matcher.matchRanked(query: query, rankedIds: candidateIds)
    }
}
