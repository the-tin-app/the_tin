import XCTest
import CryptoKit
import Gzip
@testable import TheTin

/// In-memory remote — no URLProtocol needed, ports are injected.
final class StubRemote: CatalogRemote {
    var manifest: CatalogManifest
    var files: [String: Data] = [:]
    var artifactFetches = 0

    init(manifest: CatalogManifest) { self.manifest = manifest }

    func fetchManifest() async throws -> CatalogManifest { manifest }
    func fetchData(path: String) async throws -> Data {
        if path == manifest.path { artifactFetches += 1 }
        guard let d = files[path] else { throw CatalogError.httpStatus(404) }
        return d
    }

    /// Streaming variant: reports the cumulative count at the halfway mark and at the end,
    /// like the production remotes do (chunked).
    func fetchData(path: String, onBytes: @escaping @Sendable (Int) -> Void) async throws -> Data {
        let d = try await fetchData(path: path)
        onBytes(d.count / 2)
        onBytes(d.count)
        return d
    }
}

@MainActor
private final class ProgressCollector {
    var fractions: [Double] = []
    nonisolated init() {}
}

final class CatalogUpdaterTests: XCTestCase {
    private var dir: URL!
    private var paths: CatalogPaths!
    private var gz: Data!
    private var sha: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = CatalogPaths(directory: dir)
        let sqlite = try Data(contentsOf: URL(fileURLWithPath: try FixtureCatalog.copyToTemp()))
        gz = try sqlite.gzipped()
        sha = SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined()
    }

    private func remote(version: Int) -> StubRemote {
        let m = CatalogManifest(version: version, path: "catalog/catalog-v\(version).sqlite.gz",
                                sha256: sha, sizeBytes: gz.count, generatedAt: "2026-07-04T09:00:00.000Z")
        let r = StubRemote(manifest: m)
        r.files[m.path] = gz
        return r
    }

    func testFreshInstallDownloadsVerifiesAndOpens() async throws {
        let updater = CatalogUpdater(remote: remote(version: 1), paths: paths)
        let outcome = try await updater.ensureLatest()
        XCTAssertEqual(outcome, .installed(version: 1))
        XCTAssertEqual(updater.installedState(), CatalogState(version: 1, priceAsOf: nil))
        let store = try CatalogStore(path: paths.databaseURL.path)
        XCTAssertEqual(try store.cardCount(), 7)
        try store.close()
    }

    /// Progress reports 0 as the download starts, then byte-accurate fractions against the
    /// manifest's sizeBytes — and never fires on the already-current check (no toast flash).
    func testEnsureLatestReportsProgressOnlyWhenDownloading() async throws {
        let collector = ProgressCollector()
        let updater = CatalogUpdater(remote: remote(version: 1), paths: paths)
        _ = try await updater.ensureLatest { collector.fractions.append($0) }
        // Mid-download fractions hop to the main actor via unstructured Tasks — wait them in.
        var reported = await collector.fractions
        for _ in 0..<100 where reported.count < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
            reported = await collector.fractions
        }
        XCTAssertEqual(reported.first, 0)
        XCTAssertEqual(reported.dropFirst().first ?? -1, 0.5, accuracy: 0.01)
        XCTAssertEqual(reported.last, 1)

        _ = try await updater.ensureLatest { collector.fractions.append($0) }
        reported = await collector.fractions
        XCTAssertEqual(reported.count, 3, "already-current must not report progress")
    }

    func testAlreadyCurrentSkipsDownload() async throws {
        let r = remote(version: 1)
        let updater = CatalogUpdater(remote: r, paths: paths)
        _ = try await updater.ensureLatest()
        let second = try await updater.ensureLatest()
        XCTAssertEqual(second, .alreadyCurrent(version: 1))
        XCTAssertEqual(r.artifactFetches, 1)
    }

    func testNewVersionReplacesOld() async throws {
        let updater1 = CatalogUpdater(remote: remote(version: 1), paths: paths)
        _ = try await updater1.ensureLatest()
        let updater2 = CatalogUpdater(remote: remote(version: 2), paths: paths)
        let outcome = try await updater2.ensureLatest()
        XCTAssertEqual(outcome, .installed(version: 2))
        XCTAssertEqual(updater2.installedState()?.version, 2)
    }

    func testChecksumMismatchRejectsAndLeavesNothingBehind() async throws {
        let r = remote(version: 1)
        r.manifest = CatalogManifest(version: 1, path: r.manifest.path, sha256: String(repeating: "0", count: 64),
                                     sizeBytes: gz.count, generatedAt: r.manifest.generatedAt)
        let updater = CatalogUpdater(remote: r, paths: paths)
        do {
            _ = try await updater.ensureLatest()
            XCTFail("expected checksumMismatch")
        } catch let e as CatalogError {
            XCTAssertEqual(e, .checksumMismatch)
        }
        XCTAssertNil(updater.installedState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.databaseURL.path))
    }

    func testCorruptGzipRejected() async throws {
        let r = remote(version: 1)
        let junk = Data("not gzip".utf8)
        let junkSha = SHA256.hash(data: junk).map { String(format: "%02x", $0) }.joined()
        r.manifest = CatalogManifest(version: 1, path: r.manifest.path, sha256: junkSha,
                                     sizeBytes: junk.count, generatedAt: r.manifest.generatedAt)
        r.files[r.manifest.path] = junk
        let updater = CatalogUpdater(remote: r, paths: paths)
        do {
            _ = try await updater.ensureLatest()
            XCTFail("expected corruptArtifact")
        } catch let e as CatalogError {
            XCTAssertEqual(e, .corruptArtifact)
        }
    }

    // MARK: - Tier identity

    /// Switching tiers at the SAME version must still re-download — content differs even though
    /// the version is unchanged. Without tier in the install identity this silently no-ops.
    func testTierChangeAtSameVersionRedownloads() async throws {
        let r = remote(version: 8)
        r.manifest = CatalogManifest(version: 8, path: r.manifest.path, sha256: sha,
                                     sizeBytes: gz.count, generatedAt: r.manifest.generatedAt, tier: "casual")
        let updater = CatalogUpdater(remote: r, paths: paths)
        _ = try await updater.ensureLatest()
        XCTAssertEqual(updater.installedState()?.tier, "casual")
        XCTAssertEqual(r.artifactFetches, 1)

        r.manifest = CatalogManifest(version: 8, path: r.manifest.path, sha256: sha,
                                     sizeBytes: gz.count, generatedAt: r.manifest.generatedAt, tier: "expert")
        let outcome = try await updater.ensureLatest()
        XCTAssertEqual(outcome, .installed(version: 8))
        XCTAssertEqual(updater.installedState()?.tier, "expert")
        XCTAssertEqual(r.artifactFetches, 2)
    }

    /// Same version AND same tier skips the download (no spurious re-fetch on every launch).
    func testSameTierSameVersionSkips() async throws {
        let r = remote(version: 8)
        r.manifest = CatalogManifest(version: 8, path: r.manifest.path, sha256: sha,
                                     sizeBytes: gz.count, generatedAt: r.manifest.generatedAt, tier: "average")
        let updater = CatalogUpdater(remote: r, paths: paths)
        _ = try await updater.ensureLatest()
        let outcome = try await updater.ensureLatest()
        XCTAssertEqual(outcome, .alreadyCurrent(version: 8))
        XCTAssertEqual(r.artifactFetches, 1)
    }

    // MARK: - Funding amendment

    func testFundingIsPersistedFromManifest() async throws {
        let funding = FundingSnapshot(state: .green, fundedPct: 0.75, monthlyGoalCents: 100_000,
                                       raisedCents: 75_000, updatedAt: "2026-07-04T09:00:00.000Z")
        let r = remote(version: 1)
        r.manifest = CatalogManifest(version: 1, path: r.manifest.path, sha256: sha,
                                     sizeBytes: gz.count, generatedAt: r.manifest.generatedAt, funding: funding)
        let updater = CatalogUpdater(remote: r, paths: paths)
        _ = try await updater.ensureLatest()
        XCTAssertEqual(updater.installedState()?.funding, funding)
    }

    func testAlreadyCurrentRefreshesFunding() async throws {
        let fundingA = FundingSnapshot(state: .green, fundedPct: 0.5, monthlyGoalCents: 100_000,
                                        raisedCents: 50_000, updatedAt: "2026-07-04T09:00:00.000Z")
        let fundingB = FundingSnapshot(state: .yellow, fundedPct: 0.3, monthlyGoalCents: 100_000,
                                        raisedCents: 30_000, updatedAt: "2026-07-05T09:00:00.000Z")

        let r = remote(version: 1)
        r.manifest = CatalogManifest(version: 1, path: r.manifest.path, sha256: sha,
                                     sizeBytes: gz.count, generatedAt: r.manifest.generatedAt, funding: fundingA)
        let updater = CatalogUpdater(remote: r, paths: paths)
        _ = try await updater.ensureLatest()

        // Give the installed state a non-nil priceAsOf so we can assert it survives the
        // funding-only refresh below (which must not touch version/priceAsOf).
        var state = try XCTUnwrap(updater.installedState())
        state.priceAsOf = "2026-07-04"
        try updater.saveState(state)

        r.manifest = CatalogManifest(version: 1, path: r.manifest.path, sha256: sha,
                                     sizeBytes: gz.count, generatedAt: r.manifest.generatedAt, funding: fundingB)
        let outcome = try await updater.ensureLatest()

        XCTAssertEqual(outcome, .alreadyCurrent(version: 1))
        XCTAssertEqual(r.artifactFetches, 1)
        let final = updater.installedState()
        XCTAssertEqual(final?.funding, fundingB)
        XCTAssertEqual(final?.version, 1)
        XCTAssertEqual(final?.priceAsOf, "2026-07-04")
    }

    func testNilFundingPreservesExistingSnapshot() async throws {
        let funding = FundingSnapshot(state: .green, fundedPct: 0.6, monthlyGoalCents: 100_000,
                                       raisedCents: 60_000, updatedAt: "2026-07-04T09:00:00.000Z")
        // v1 install carries funding (as if last served by Firebase).
        let r = remote(version: 1)
        r.manifest = CatalogManifest(version: 1, path: r.manifest.path, sha256: sha,
                                     sizeBytes: gz.count, generatedAt: r.manifest.generatedAt, funding: funding)
        let updater = CatalogUpdater(remote: r, paths: paths)
        _ = try await updater.ensureLatest()
        XCTAssertEqual(updater.installedState()?.funding, funding)

        // Now a self-host manifest with NO funding for the same version must not blank it.
        r.manifest = CatalogManifest(version: 1, path: r.manifest.path, sha256: sha,
                                     sizeBytes: gz.count, generatedAt: r.manifest.generatedAt, funding: nil)
        let outcome = try await updater.ensureLatest()
        XCTAssertEqual(outcome, .alreadyCurrent(version: 1))
        XCTAssertEqual(updater.installedState()?.funding, funding)   // preserved
    }

    func testNilFundingOnUpgradePreservesSnapshot() async throws {
        let funding = FundingSnapshot(state: .yellow, fundedPct: 0.4, monthlyGoalCents: 100_000,
                                       raisedCents: 40_000, updatedAt: "2026-07-04T09:00:00.000Z")
        let r1 = remote(version: 1)
        r1.manifest = CatalogManifest(version: 1, path: r1.manifest.path, sha256: sha,
                                      sizeBytes: gz.count, generatedAt: r1.manifest.generatedAt, funding: funding)
        let u1 = CatalogUpdater(remote: r1, paths: paths)
        _ = try await u1.ensureLatest()

        // Self-host v2 upgrade (funding nil) must carry the prior funding forward.
        let u2 = CatalogUpdater(remote: remote(version: 2), paths: paths)   // remote() builds funding: nil
        let outcome = try await u2.ensureLatest()
        XCTAssertEqual(outcome, .installed(version: 2))
        XCTAssertEqual(u2.installedState()?.funding, funding)
    }
}
