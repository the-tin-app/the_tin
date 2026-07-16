import XCTest
import CryptoKit
import Gzip
import GRDB
@testable import TheTin

final class StubFPRemote: FingerprintRemote {
    var manifest: FingerprintManifest
    var files: [String: Data] = [:]
    var artifactFetches = 0
    init(manifest: FingerprintManifest) { self.manifest = manifest }
    func fetchManifest() async throws -> FingerprintManifest { manifest }
    func fetchData(path: String) async throws -> Data {
        if path == manifest.path { artifactFetches += 1 }
        guard let d = files[path] else { throw CatalogError.httpStatus(404) }
        return d
    }
    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data {
        let d = try await fetchData(path: path)
        onBytes(d.count / 2)
        onBytes(d.count)
        return d
    }
}

final class FingerprintUpdaterTests: XCTestCase {
    private var env: FingerprintUpdaterTestEnv!
    private var paths: FingerprintPaths { env.paths }
    private var gz: Data { env.gz }
    private var sha: String { env.sha }
    private let goodHash = FingerprintConstants.codebookSHA256

    override func setUpWithError() throws {
        env = try FingerprintUpdaterTestEnv.make()
    }

    private func manifest(version: Int, fpVersion: Int = 1, codebookHash: String? = nil) -> FingerprintManifest {
        FingerprintUpdaterTestEnv.manifest(version: version, gz: gz, sha: sha, fpVersion: fpVersion, codebookHash: codebookHash)
    }
    private func remote(_ m: FingerprintManifest) -> StubFPRemote {
        let r = StubFPRemote(manifest: m); r.files[m.path] = gz; return r
    }

    func testFreshInstallDownloadsAndOpens() async throws {
        let updater = FingerprintUpdater(remote: remote(manifest(version: 1)), paths: paths)
        let outcome = try await updater.ensureLatest()
        XCTAssertEqual(outcome, .installed(version: 1))
        XCTAssertEqual(updater.installedState(), FingerprintState(version: 1, fpVersion: 1, codebookHash: goodHash))
        let store = try FingerprintStore(path: paths.databaseURL.path)
        XCTAssertEqual(try store.cardCount(), 2)
        try store.close()
    }

    /// Mirrors CatalogUpdater's onProgress contract: 0 as the download starts, then
    /// byte-accurate fractions against the manifest's sizeBytes, reaching 1.
    @MainActor
    func testEnsureLatestReportsProgress() async throws {
        let updater = FingerprintUpdater(remote: remote(manifest(version: 1)), paths: paths)
        var fractions: [Double] = []
        _ = try await updater.ensureLatest { fractions.append($0) }
        for _ in 0..<20 where !fractions.contains(1) { await Task.yield() }
        XCTAssertEqual(fractions.first, 0, "progress must start at 0 when a download begins")
        XCTAssertTrue(fractions.contains(1), "progress must reach 1 when the pack finishes: \(fractions)")
    }

    func testAlreadyCurrentSkipsDownload() async throws {
        let r = remote(manifest(version: 1))
        let updater = FingerprintUpdater(remote: r, paths: paths)
        _ = try await updater.ensureLatest()
        let second = try await updater.ensureLatest()
        XCTAssertEqual(second, .alreadyCurrent(version: 1))
        XCTAssertEqual(r.artifactFetches, 1)
    }

    func testIsCurrentFalseWhenInstalledFpVersionIsStale() async throws {
        // Install v1 / fpVersion 1, then the server advertises fpVersion 2 (an nf bump).
        _ = try await FingerprintUpdater(remote: remote(manifest(version: 1, fpVersion: 1)), paths: paths).ensureLatest()
        let updater = FingerprintUpdater(remote: remote(manifest(version: 1, fpVersion: 2)), paths: paths)
        let current = try await updater.isCurrent()
        XCTAssertFalse(current, "a stale fpVersion must report not-current so the gate re-downloads")
    }

    func testIsCurrentTrueWhenInstalledMatchesManifest() async throws {
        _ = try await FingerprintUpdater(remote: remote(manifest(version: 1, fpVersion: 1)), paths: paths).ensureLatest()
        let updater = FingerprintUpdater(remote: remote(manifest(version: 1, fpVersion: 1)), paths: paths)
        let current = try await updater.isCurrent()
        XCTAssertTrue(current, "a matching installed pack must report current")
    }

    func testIsCurrentFalseWhenNothingInstalled() async throws {
        let updater = FingerprintUpdater(remote: remote(manifest(version: 1)), paths: paths)   // fresh temp dir
        let current = try await updater.isCurrent()
        XCTAssertFalse(current, "no installed pack must report not-current")
    }

    func testNewVersionReplaces() async throws {
        _ = try await FingerprintUpdater(remote: remote(manifest(version: 1)), paths: paths).ensureLatest()
        let updater2 = FingerprintUpdater(remote: remote(manifest(version: 2)), paths: paths)
        let outcome = try await updater2.ensureLatest()
        XCTAssertEqual(outcome, .installed(version: 2))
        XCTAssertEqual(updater2.installedState()?.version, 2)
    }

    func testChecksumMismatchRejected() async throws {
        let r = remote(manifest(version: 1))
        r.manifest = FingerprintManifest(version: 1, path: r.manifest.path, sha256: String(repeating: "0", count: 64),
                                         sizeBytes: gz.count, generatedAt: r.manifest.generatedAt, fpVersion: 1,
                                         codebookHash: goodHash, canonicalW: 660, canonicalH: 920)
        let updater = FingerprintUpdater(remote: r, paths: paths)
        do { _ = try await updater.ensureLatest(); XCTFail("expected checksumMismatch") }
        catch let e as CatalogError { XCTAssertEqual(e, .checksumMismatch) }
        XCTAssertNil(updater.installedState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.databaseURL.path))
    }

    func testCorruptGzipRejected() async throws {
        let r = remote(manifest(version: 1))
        let junk = Data("not gzip".utf8)
        let junkSha = SHA256.hash(data: junk).map { String(format: "%02x", $0) }.joined()
        r.manifest = FingerprintManifest(version: 1, path: r.manifest.path, sha256: junkSha, sizeBytes: junk.count,
                                         generatedAt: r.manifest.generatedAt, fpVersion: 1, codebookHash: goodHash,
                                         canonicalW: 660, canonicalH: 920)
        r.files[r.manifest.path] = junk
        let updater = FingerprintUpdater(remote: r, paths: paths)
        do { _ = try await updater.ensureLatest(); XCTFail("expected corruptArtifact") }
        catch let e as CatalogError { XCTAssertEqual(e, .corruptArtifact) }
    }

    // Extra gate vs catalog #1: a pack for a codebook the app doesn't bundle must never install.
    func testIncompatibleCodebookRejected() async throws {
        let r = remote(manifest(version: 1, codebookHash: String(repeating: "a", count: 64)))
        let updater = FingerprintUpdater(remote: r, paths: paths)
        do { _ = try await updater.ensureLatest(); XCTFail("expected incompatibleCodebook") }
        catch let e as CatalogError { XCTAssertEqual(e, .incompatibleCodebook) }
        XCTAssertNil(updater.installedState())
        XCTAssertEqual(r.artifactFetches, 0, "must reject before downloading the artifact")
    }

    // Extra gate vs catalog #2: same version but a bumped fpVersion forces re-download.
    func testFpVersionBumpRedownloads() async throws {
        let updater = FingerprintUpdater(remote: remote(manifest(version: 1, fpVersion: 1)), paths: paths)
        _ = try await updater.ensureLatest()
        let r2 = remote(manifest(version: 1, fpVersion: 2))
        let updater2 = FingerprintUpdater(remote: r2, paths: paths)
        let outcome = try await updater2.ensureLatest()
        XCTAssertEqual(outcome, .installed(version: 1))
        XCTAssertEqual(r2.artifactFetches, 1)
        XCTAssertEqual(updater2.installedState()?.fpVersion, 2)
    }

    // Guard: Gate 0 only checks the *manifest's* claimed codebookHash. A stale CDN edge or a
    // manifest/artifact mismatch could still serve a pack whose own embedded meta.codebook_hash
    // disagrees; the sanity probe must catch that too. Built from scratch (no committed binary
    // fixture) so the schema mirrors fpcore.fpdb's meta/card_fp tables.
    func testProbeRejectsPackWhoseEmbeddedMetaHashDiffersFromManifest() async throws {
        let badPath = NSTemporaryDirectory() + "fp-badmeta-\(UUID().uuidString).sqlite"
        let q = try DatabaseQueue(path: badPath)
        try await q.write { db in
            try db.execute(sql: """
            CREATE TABLE meta(fp_version INTEGER, codebook_hash TEXT, canonical_w INTEGER, canonical_h INTEGER, built_at TEXT);
            CREATE TABLE card_fp(card_id TEXT PRIMARY KEY, fp_version INTEGER, global_vec BLOB, kp_count INTEGER, keypoints BLOB, descriptors BLOB);
            """)
            try db.execute(sql: "INSERT INTO meta(fp_version, codebook_hash, canonical_w, canonical_h, built_at) VALUES (1, ?, 660, 920, '2026-07-07T00:00:00.000Z')",
                            arguments: [String(repeating: "b", count: 64)])
            try db.execute(sql: "INSERT INTO card_fp(card_id) VALUES ('x')")
        }
        try q.close()

        let badGz = try Data(contentsOf: URL(fileURLWithPath: badPath)).gzipped()
        let badSha = SHA256.hash(data: badGz).map { String(format: "%02x", $0) }.joined()
        let m = FingerprintManifest(version: 1, path: "fingerprint/fingerprints-v1.sqlite.gz", sha256: badSha,
                                    sizeBytes: badGz.count, generatedAt: "2026-07-07T00:00:00.000Z", fpVersion: 1,
                                    codebookHash: goodHash, canonicalW: 660, canonicalH: 920) // manifest claims goodHash
        let r = StubFPRemote(manifest: m); r.files[m.path] = badGz
        let updater = FingerprintUpdater(remote: r, paths: paths)
        do { _ = try await updater.ensureLatest(); XCTFail("expected incompatibleCodebook") }
        catch let e as CatalogError { XCTAssertEqual(e, .incompatibleCodebook) }
        XCTAssertNil(updater.installedState())
    }
}
