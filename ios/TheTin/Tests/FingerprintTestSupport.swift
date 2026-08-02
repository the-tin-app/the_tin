import CoreImage
import CoreVideo
import Foundation
@testable import TheTin

/// Shared fixture builders for fingerprint/matcher/scan tests — kept in one place so
/// `PixelFingerprintParityTests`, `MatcherGatedTests`, and `ScanModelTests` don't each
/// re-implement the same PNG→CVPixelBuffer render or sqlite-fixture copy/open dance.
enum TestPixelBuffer {
    /// Renders card_a's source PNG (via CIContext) into a canonical 660x920
    /// `kCVPixelFormatType_32BGRA` CVPixelBuffer — the same shape a real device
    /// perspective-corrected plate would be, so it can drive `CardDetector`'s
    /// canonical-size passthrough branch (see CardDetector.swift) in headless tests.
    static func canonicalCardA(bundle: Bundle) throws -> CVPixelBuffer {
        guard let url = bundle.url(forResource: "card_a", withExtension: "pngdata") else {
            throw NSError(domain: "TestPixelBuffer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "card_a.pngdata missing from test bundle"])
        }
        guard let ci = CIImage(data: try Data(contentsOf: url)) else {
            throw NSError(domain: "TestPixelBuffer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "failed to decode card_a.pngdata"])
        }
        let w = FingerprintConstants.canonW, h = FingerprintConstants.canonH
        let scaled = ci.transformed(by: CGAffineTransform(
            scaleX: CGFloat(w) / ci.extent.width, y: CGFloat(h) / ci.extent.height))

        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else {
            throw NSError(domain: "TestPixelBuffer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed (\(status))"])
        }
        let ctx = CIContext()
        ctx.render(scaled, to: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                  colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }

    /// Copies BGRA bytes straight out of a locked CVPixelBuffer (no resampling) — used by
    /// tests that need the raw plate bytes/stride rather than the buffer itself.
    static func bgraBytes(from pixelBuffer: CVPixelBuffer) -> (data: Data, bytesPerRow: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
        return (Data(bytes: base, count: stride * height), stride)
    }
}

/// Always throws — the down-origin fixture for `FailoverFingerprintRemote` tests.
struct FailingFingerprintRemote: FingerprintRemote {
    func fetchManifest() async throws -> FingerprintManifest { throw CatalogError.httpStatus(500) }
    func fetchPartsManifest() async throws -> FingerprintPartsManifest { throw CatalogError.httpStatus(500) }
    func fetchData(path: String) async throws -> Data { throw CatalogError.httpStatus(500) }
}

/// Serves a minimal parts manifest stamped with `version`, and `data` from `fetchData` — enough
/// for failover tests to tell which origin answered, without needing a real pack fixture.
struct StubPartsFingerprintRemote: FingerprintRemote {
    let version: Int
    var data: Data = Data()
    func fetchManifest() async throws -> FingerprintManifest {
        FingerprintManifest(version: version, path: "fingerprint/fingerprints-v\(version).sqlite.gz",
                            sha256: "", sizeBytes: 0, generatedAt: "", fpVersion: 1,
                            codebookHash: FingerprintConstants.codebookSHA256, canonicalW: 660, canonicalH: 920)
    }
    func fetchPartsManifest() async throws -> FingerprintPartsManifest {
        FingerprintPartsManifest(version: version, partSize: 4096, parts: [], sha256: "",
                                 sizeBytes: 0, generatedAt: "", fpVersion: 1,
                                 codebookHash: FingerprintConstants.codebookSHA256, canonicalW: 660, canonicalH: 920)
    }
    func fetchData(path: String) async throws -> Data { data }
    /// Streams like a real origin would — needed so a failover test can observe that progress
    /// callbacks actually fire on the fallback path, not just that the bytes come back correct.
    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data {
        onBytes(data.count / 2)
        onBytes(data.count)
        return data
    }
}

enum FingerprintTestSupport {
    /// Copies the shipped `fingerprints-fixture.sqlite` fixture to a scratch temp path
    /// and opens it — GRDB needs a writable-location DB file, not a bundle resource URL.
    static func openFixtureStore(bundle: Bundle) throws -> FingerprintStore {
        guard let src = bundle.url(forResource: "fingerprints-fixture", withExtension: "sqlite") else {
            throw NSError(domain: "FingerprintTestSupport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "fingerprints-fixture.sqlite missing from test bundle"])
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        try FileManager.default.copyItem(at: src, to: tmp)
        return try FingerprintStore(path: tmp.path)
    }
}
