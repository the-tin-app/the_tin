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
    /// Raw (ungzipped) fixture pack — the bytes the parts format serves.
    var sqlite: Data = Data()

    static let goodHash = FingerprintConstants.codebookSHA256

    /// The fixture pack's raw bytes, straight from the test bundle.
    static func fixtureSqlite() throws -> Data {
        guard let src = Bundle(for: FingerprintUpdaterTestEnvToken.self)
            .url(forResource: "fingerprints-fixture", withExtension: "sqlite") else {
            throw NSError(domain: "FingerprintUpdaterTestEnv", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "fingerprints-fixture.sqlite missing from test bundle"])
        }
        return try Data(contentsOf: src)
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Split `sqlite` the way `fpcore.publish.split_into_parts` does, and build the matching
    /// manifest + per-part payloads.
    static func partsManifest(version: Int, sqlite: Data, partSize: Int, fpVersion: Int = 1,
                              codebookHash: String? = nil)
        -> (manifest: FingerprintPartsManifest, files: [String: Data]) {
        var entries: [FingerprintPartsManifest.Part] = []
        var files: [String: Data] = [:]
        var offset = 0
        while offset < sqlite.count {
            let chunk = sqlite.subdata(in: offset..<min(offset + partSize, sqlite.count))
            let path = "fingerprint/parts/fingerprints-v\(version).part\(String(format: "%03d", entries.count))"
            entries.append(.init(path: path, sha256: hex(chunk), bytes: chunk.count))
            files[path] = chunk
            offset += partSize
        }
        let m = FingerprintPartsManifest(
            version: version, partSize: partSize, parts: entries, sha256: hex(sqlite),
            sizeBytes: sqlite.count, generatedAt: "2026-07-24T00:00:00.000Z", fpVersion: fpVersion,
            codebookHash: codebookHash ?? goodHash, canonicalW: 660, canonicalH: 920)
        return (m, files)
    }

    /// Fresh temp install dir + a remote serving `version` of the fixture pack in the **parts**
    /// format (and the legacy pair too, so fallback behaviour can be exercised from the same env).
    static func makeParts(version: Int = 1, partSize: Int = 4096, fpVersion: Int = 1,
                          codebookHash: String? = nil) throws -> FingerprintUpdaterTestEnv {
        var env = try make(version: version, fpVersion: fpVersion, codebookHash: codebookHash)
        let sqlite = try fixtureSqlite()
        let (m, files) = partsManifest(version: version, sqlite: sqlite, partSize: partSize,
                                       fpVersion: fpVersion, codebookHash: codebookHash)
        env.remote.partsManifest = m
        for (path, data) in files { env.remote.files[path] = data }
        env.sqlite = sqlite
        return env
    }

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
