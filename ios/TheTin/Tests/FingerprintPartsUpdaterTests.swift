import XCTest
import CryptoKit
@testable import TheTin

/// The parts distribution format: a pack downloaded as fixed-size chunks written straight to
/// their final offsets, resumable across failures and launches. Legacy single-file behaviour
/// stays covered by `FingerprintUpdaterTests`.
final class FingerprintPartsUpdaterTests: XCTestCase {
    private var env: FingerprintUpdaterTestEnv!
    private var paths: FingerprintPaths { env.paths }

    override func setUpWithError() throws {
        // 4 KiB parts over the 64 KiB fixture ⇒ 16 parts, enough to interrupt partway.
        env = try FingerprintUpdaterTestEnv.makeParts(partSize: 4096)
    }

    private func installedPackBytes() throws -> Data {
        try Data(contentsOf: paths.databaseURL)
    }

    func testFreshInstallFromPartsProducesTheExactPack() async throws {
        let updater = FingerprintUpdater(remote: env.remote, paths: paths)

        let outcome = try await updater.ensureLatest()

        XCTAssertEqual(outcome, .installed(version: 1))
        XCTAssertEqual(try installedPackBytes(), env.sqlite,
                       "parts must reassemble to the published pack byte-for-byte")
        let store = try FingerprintStore(path: paths.databaseURL.path)
        XCTAssertEqual(try store.cardCount(), 2)
        try store.close()
        XCTAssertEqual(env.remote.artifactFetches, 0, "the legacy single-file pack must not be fetched")
    }

    func testInterruptedDownloadResumesWithoutRefetchingCompletedParts() async throws {
        env.remote.failAfterParts = 6
        let first = FingerprintUpdater(remote: env.remote, paths: paths)
        do { _ = try await first.ensureLatest(); XCTFail("expected the simulated drop to throw") }
        catch {}

        let ledger = try XCTUnwrap(first.downloadState(), "a partial download must leave a resume ledger")
        XCTAssertEqual(ledger.completedParts.count, 6)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.databaseURL.path),
                       "nothing may be installed from a partial download")

        env.remote.failAfterParts = nil
        let resumed = FingerprintUpdater(remote: env.remote, paths: paths)
        let outcome = try await resumed.ensureLatest()

        XCTAssertEqual(outcome, .installed(version: 1))
        XCTAssertEqual(try installedPackBytes(), env.sqlite)
        let total = env.remote.partsManifest!.parts.count
        XCTAssertEqual(env.remote.partFetchCount, total,
                       "each part must be fetched exactly once across the interrupted + resumed runs")
        XCTAssertNil(resumed.downloadState(), "a completed install must clear the resume ledger")
    }

    /// The reason to resume at all: a failure near the end must not re-cost the whole pack.
    func testResumeSkipsTheBytesAlreadyOnDisk() async throws {
        env.remote.failAfterParts = 15               // 16 parts total — drop on the last one
        _ = try? await FingerprintUpdater(remote: env.remote, paths: paths).ensureLatest()
        env.remote.failAfterParts = nil
        env.remote.fetches = [:]

        _ = try await FingerprintUpdater(remote: env.remote, paths: paths).ensureLatest()

        XCTAssertEqual(env.remote.partFetchCount, 1, "only the missing part should be refetched")
    }

    func testProgressResumesFromBytesAlreadyDownloaded() async throws {
        env.remote.failAfterParts = 8
        _ = try? await FingerprintUpdater(remote: env.remote, paths: paths).ensureLatest()
        env.remote.failAfterParts = nil

        let updater = FingerprintUpdater(remote: env.remote, paths: paths)
        let box = ProgressBox()
        _ = try await updater.ensureLatest { p in box.append(p) }
        for _ in 0..<50 where box.last()?.bytesDone != env.sqlite.count { await Task.yield() }

        let first = try XCTUnwrap(box.first())
        XCTAssertEqual(first.bytesDone, 8 * 4096,
                       "a resumed download must report the bytes already on disk, not restart at 0")
        XCTAssertEqual(first.totalBytes, env.sqlite.count)
        XCTAssertEqual(box.last()?.bytesDone, env.sqlite.count)
    }

    func testCorruptPartIsRejectedAndNothingInstalls() async throws {
        let victim = env.remote.partsManifest!.parts[3]
        env.remote.files[victim.path] = Data(repeating: 0xAB, count: victim.bytes)  // right size, wrong bytes
        let updater = FingerprintUpdater(remote: env.remote, paths: paths)

        do { _ = try await updater.ensureLatest(); XCTFail("expected checksumMismatch") }
        catch let e as CatalogError { XCTAssertEqual(e, .checksumMismatch) }

        XCTAssertNil(updater.installedState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.databaseURL.path))
        XCTAssertEqual(updater.downloadState()?.completedParts.count, 3,
                       "the parts that did verify stay on disk — only the bad one is refetched")
    }

    /// A partial download belonging to a *different* published pack must never be stitched into
    /// the new one. Same part size, different version ⇒ different bytes at the same offsets.
    func testPartialFromAnotherPackVersionIsDiscarded() async throws {
        env.remote.failAfterParts = 5
        _ = try? await FingerprintUpdater(remote: env.remote, paths: paths).ensureLatest()
        XCTAssertEqual(FingerprintUpdater(remote: env.remote, paths: paths).downloadState()?.version, 1)

        // The server moves to v2; the stale v1 partial must not be resumed into it.
        let (m2, files2) = FingerprintUpdaterTestEnv.partsManifest(
            version: 2, sqlite: env.sqlite, partSize: 4096)
        env.remote.partsManifest = m2
        for (path, data) in files2 { env.remote.files[path] = data }
        env.remote.failAfterParts = nil
        env.remote.fetches = [:]

        let updater = FingerprintUpdater(remote: env.remote, paths: paths)
        let outcome = try await updater.ensureLatest()

        XCTAssertEqual(outcome, .installed(version: 2))
        XCTAssertEqual(env.remote.partFetchCount, m2.parts.count,
                       "every part of the new pack must be fetched — none inherited from the old partial")
        XCTAssertEqual(try installedPackBytes(), env.sqlite)
    }

    func testIncompatibleCodebookRejectedBeforeFetchingAnyPart() async throws {
        let (bad, files) = FingerprintUpdaterTestEnv.partsManifest(
            version: 1, sqlite: env.sqlite, partSize: 4096,
            codebookHash: String(repeating: "a", count: 64))
        env.remote.partsManifest = bad
        for (path, data) in files { env.remote.files[path] = data }

        let updater = FingerprintUpdater(remote: env.remote, paths: paths)
        do { _ = try await updater.ensureLatest(); XCTFail("expected incompatibleCodebook") }
        catch let e as CatalogError { XCTAssertEqual(e, .incompatibleCodebook) }

        XCTAssertEqual(env.remote.partFetchCount, 0, "must reject before downloading anything")
        XCTAssertNil(updater.installedState())
    }

    // MARK: Rollout — the two formats must not strand each other

    /// A host that serves no parts manifest (not yet republished) must still install via the
    /// legacy single-file pack, so shipping the client before the pipeline runs is safe.
    func testFallsBackToLegacyWhenTheHostServesNoParts() async throws {
        env.remote.partsManifest = nil
        let updater = FingerprintUpdater(remote: env.remote, paths: paths)

        let outcome = try await updater.ensureLatest()

        XCTAssertEqual(outcome, .installed(version: 1))
        XCTAssertEqual(env.remote.artifactFetches, 1, "the legacy artifact is the fallback")
        XCTAssertEqual(env.remote.partFetchCount, 0)
    }

    /// The migration case that matters most: a pack already installed via the legacy format
    /// satisfies the parts manifest's gates, so nobody re-downloads ~800 MB to change format.
    func testLegacyInstallSatisfiesThePartsManifestWithoutRedownloading() async throws {
        env.remote.partsManifest = nil
        _ = try await FingerprintUpdater(remote: env.remote, paths: paths).ensureLatest()

        let (m, files) = FingerprintUpdaterTestEnv.partsManifest(
            version: 1, sqlite: env.sqlite, partSize: 4096)
        env.remote.partsManifest = m
        for (path, data) in files { env.remote.files[path] = data }

        let updater = FingerprintUpdater(remote: env.remote, paths: paths)
        let outcome = try await updater.ensureLatest()

        XCTAssertEqual(outcome, .alreadyCurrent(version: 1))
        XCTAssertEqual(env.remote.partFetchCount, 0, "changing format must not re-cost the pack")
    }

    func testIsCurrentReadsThePartsManifestWhenServed() async throws {
        _ = try await FingerprintUpdater(remote: env.remote, paths: paths).ensureLatest()
        let installed = try await FingerprintUpdater(remote: env.remote, paths: paths).isCurrent()
        XCTAssertTrue(installed)

        let (m2, files2) = FingerprintUpdaterTestEnv.partsManifest(
            version: 2, sqlite: env.sqlite, partSize: 4096)
        env.remote.partsManifest = m2
        for (path, data) in files2 { env.remote.files[path] = data }
        let current = try await FingerprintUpdater(remote: env.remote, paths: paths).isCurrent()
        XCTAssertFalse(current, "a newer parts manifest must report not-current")
    }

    func testDiscardPartialDownloadClearsBothFileAndLedger() async throws {
        env.remote.failAfterParts = 4
        let updater = FingerprintUpdater(remote: env.remote, paths: paths)
        _ = try? await updater.ensureLatest()
        XCTAssertNotNil(updater.downloadState())

        updater.discardPartialDownload()

        XCTAssertNil(updater.downloadState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.incomingURL.path))
    }

    // MARK: Failover — see FailoverFingerprintRemote

    func testPackFailoverUsesTheBackupWhenThePrimaryFails() async throws {
        let primary = FailingFingerprintRemote()
        let backup = StubPartsFingerprintRemote(version: 3)
        let remote = FailoverFingerprintRemote(primary: primary, fallback: backup)
        let manifest = try await remote.fetchPartsManifest()
        XCTAssertEqual(manifest.version, 3)
    }

    func testPackFailoverPrefersThePrimary() async throws {
        let primary = StubPartsFingerprintRemote(version: 3)
        let backup = FailingFingerprintRemote()
        let remote = FailoverFingerprintRemote(primary: primary, fallback: backup)
        let manifest = try await remote.fetchPartsManifest()
        XCTAssertEqual(manifest.version, 3)
    }

    func testPackFailoverPropagatesTheBackupsErrorWhenBothFail() async {
        let remote = FailoverFingerprintRemote(primary: FailingFingerprintRemote(),
                                               fallback: FailingFingerprintRemote())
        do { _ = try await remote.fetchPartsManifest(); XCTFail("expected a throw") }
        catch { /* expected — one honest retryable error, not a swallowed nil */ }
    }
}

/// Collects `onProgress` callbacks, which arrive on the main actor from detached hops.
private final class ProgressBox: @unchecked Sendable {
    private var values: [FingerprintDownloadProgress] = []
    private let lock = NSLock()

    func append(_ p: FingerprintDownloadProgress) {
        lock.lock(); defer { lock.unlock() }
        values.append(p)
    }
    func first() -> FingerprintDownloadProgress? {
        lock.lock(); defer { lock.unlock() }
        return values.first
    }
    func last() -> FingerprintDownloadProgress? {
        lock.lock(); defer { lock.unlock() }
        return values.last
    }
}
