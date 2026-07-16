import Foundation
import CryptoKit
import Gzip
@testable import TheTin

private final class FingerprintUpdaterTestEnvToken {}

/// Shared scaffolding for `FingerprintUpdaterTests` and `ScanGateTests`: a fresh temp
/// install directory (no pack installed yet) + a `StubFPRemote` serving the fixture
/// pack (gzipped `fingerprints-fixture.sqlite`) and its manifest. Extracted from
/// `FingerprintUpdaterTests` so `ScanGateTests` can drive the same fake-remote /
/// temp-paths dance without re-deriving it.
struct FingerprintUpdaterTestEnv {
    let dir: URL
    let paths: FingerprintPaths
    let gz: Data
    let sha: String
    let remote: StubFPRemote
    let updater: FingerprintUpdater
    let makeStore: (String) throws -> FingerprintStore

    static let goodHash = FingerprintConstants.codebookSHA256

    static func manifest(version: Int, gz: Data, sha: String, fpVersion: Int = 1,
                         codebookHash: String? = nil) -> FingerprintManifest {
        FingerprintManifest(version: version, path: "fingerprint/fingerprints-v\(version).sqlite.gz",
                            sha256: sha, sizeBytes: gz.count, generatedAt: "2026-07-07T00:00:00.000Z",
                            fpVersion: fpVersion, codebookHash: codebookHash ?? goodHash,
                            canonicalW: 660, canonicalH: 920)
    }

    /// Fresh temp install dir (no pack present) + a remote already serving `version` of
    /// the fixture pack under a matching manifest.
    static func make(version: Int = 1, fpVersion: Int = 1, codebookHash: String? = nil) throws -> FingerprintUpdaterTestEnv {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = FingerprintPaths(directory: dir)
        guard let src = Bundle(for: FingerprintUpdaterTestEnvToken.self)
            .url(forResource: "fingerprints-fixture", withExtension: "sqlite") else {
            throw NSError(domain: "FingerprintUpdaterTestEnv", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "fingerprints-fixture.sqlite missing from test bundle"])
        }
        let gz = try Data(contentsOf: src).gzipped()
        let sha = SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined()
        let m = manifest(version: version, gz: gz, sha: sha, fpVersion: fpVersion, codebookHash: codebookHash)
        let r = StubFPRemote(manifest: m)
        r.files[m.path] = gz
        return FingerprintUpdaterTestEnv(dir: dir, paths: paths, gz: gz, sha: sha, remote: r,
                                         updater: FingerprintUpdater(remote: r, paths: paths),
                                         makeStore: { try FingerprintStore(path: $0) })
    }
}
