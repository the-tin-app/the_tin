import XCTest
@testable import TheTin

/// Simulates the self-hosted server rejecting the device (e.g. App Attest env mismatch):
/// every call fails auth, exactly what a production build sees against a dev-mode server.
private struct RejectingFPRemote: FingerprintRemote {
    func fetchManifest() async throws -> FingerprintManifest { throw CatalogError.httpStatus(401) }
    func fetchData(path: String) async throws -> Data { throw CatalogError.httpStatus(401) }
}

final class ScannerPackModelTests: XCTestCase {
    @MainActor
    private func makePack(env: FingerprintUpdaterTestEnv,
                          updater: FingerprintUpdater? = nil,
                          fallback: FingerprintUpdater? = nil) throws -> ScannerPackModel {
        ScannerPackModel(updater: updater ?? env.updater, fallbackUpdater: fallback,
                         paths: env.paths, catalogStore: try FixtureCatalog.make(),
                         makeStore: env.makeStore,
                         makeCodebook: { try Codebook.bundled(in: Bundle(for: Self.self)) })
    }

    /// Mirrors the catalog's whole-operation failover: when the self-hosted pack download
    /// fails (dev-mode server rejecting prod App Attest), the pack must retry the entire
    /// update against the Firebase fallback instead of stranding on "Download failed".
    @MainActor
    func testDownloadFailsOverToFallbackUpdater() async throws {
        let env = try FingerprintUpdaterTestEnv.make()   // working remote → the fallback
        let primary = FingerprintUpdater(remote: RejectingFPRemote(), paths: env.paths)
        let pack = try makePack(env: env, updater: primary, fallback: env.updater)

        await pack.refresh()
        XCTAssertEqual(pack.phase, .notInstalled)
        pack.startDownload()
        await pack.waitForDownload()

        XCTAssertEqual(pack.phase, .ready)
    }

    /// No fallback configured (Firebase-only wiring): a failed download must surface a
    /// retryable state, not crash or spin.
    @MainActor
    func testDownloadFailureWithoutFallbackIsUnavailable() async throws {
        let env = try FingerprintUpdaterTestEnv.make()
        let primary = FingerprintUpdater(remote: RejectingFPRemote(), paths: env.paths)
        let pack = try makePack(env: env, updater: primary)

        pack.startDownload()
        await pack.waitForDownload()

        XCTAssertEqual(pack.phase,
                       .unavailable("Download failed. Check your connection and try again."))
    }

    @MainActor
    func testMissingPackRequiresDownloadThenReady() async throws {
        let env = try FingerprintUpdaterTestEnv.make()   // temp paths + fake remote, no installed pack
        let pack = try makePack(env: env)

        await pack.refresh()
        XCTAssertEqual(pack.phase, .notInstalled)
        pack.startDownload()
        await pack.waitForDownload()

        XCTAssertEqual(pack.phase, .ready)
        XCTAssertEqual(pack.installedVersion, 1)
        XCTAssertNotNil(pack.installedBytes)
    }

    /// Regression guard: a pack file that EXISTS but can't be opened (corrupt/truncated/garbage
    /// bytes) must never crash the process, and must never report `.ready` with a nil matcher
    /// (which would strand the UI behind a `ProgressView()` forever).
    @MainActor
    func testPresentButUnopenablePackDegradesToUnavailable() async throws {
        let env = try FingerprintUpdaterTestEnv.make()
        // Installed-AND-current but corrupt: matching state.json (so the freshness check reports
        // current, not stale) + garbage where the sqlite pack is expected.
        try env.updater.saveState(FingerprintState(version: 1, fpVersion: 1,
                                                   codebookHash: FingerprintUpdaterTestEnv.goodHash))
        try Data("not a sqlite database".utf8).write(to: env.paths.databaseURL)
        let pack = try makePack(env: env)

        await pack.refresh() // must not crash

        XCTAssertEqual(pack.phase, .unavailable("Scanner data unavailable."))
        XCTAssertNil(pack.matcher)
        XCTAssertNil(pack.index)
    }

    // MARK: Don't take a working scanner away for a merely-old pack

    /// The stale-pack trap this replaces: any non-current pack used to route straight back to the
    /// download wall, so a user one version behind lost a working scanner to a ~500 MB download.
    /// A newer `version` alone must keep the installed pack in service and merely offer an update.
    @MainActor
    func testOlderVersionKeepsScanningAndOffersAnUpdate() async throws {
        let env = try FingerprintUpdaterTestEnv.make(version: 1)
        _ = try await env.updater.ensureLatest()
        env.remote.manifest = FingerprintUpdaterTestEnv.manifest(version: 2, gz: env.gz, sha: env.sha)
        let pack = try makePack(env: env)

        await pack.refresh()

        XCTAssertEqual(pack.phase, .ready, "an older but compatible pack must keep working")
        XCTAssertTrue(pack.updateAvailable)
        XCTAssertEqual(pack.installedVersion, 1)
    }

    /// The opposite case: a bumped fpVersion means the installed pack would silently mismatch,
    /// so it genuinely has to be replaced before scanning again.
    @MainActor
    func testIncompatibleFpVersionDoesRequireRedownload() async throws {
        let env = try FingerprintUpdaterTestEnv.make(version: 1, fpVersion: 1)
        _ = try await env.updater.ensureLatest()
        env.remote.manifest = FingerprintUpdaterTestEnv.manifest(version: 1, gz: env.gz, sha: env.sha,
                                                                 fpVersion: 2)
        let pack = try makePack(env: env)

        await pack.refresh()

        XCTAssertEqual(pack.phase, .notInstalled)
    }

    /// Offline must not read as "your scanner is gone" — an unreachable manifest falls back to
    /// whatever is installed, which is the whole promise of an offline scanner.
    @MainActor
    func testUnreachableManifestKeepsUsingTheInstalledPack() async throws {
        let env = try FingerprintUpdaterTestEnv.make()
        _ = try await env.updater.ensureLatest()
        let offline = FingerprintUpdater(remote: RejectingFPRemote(), paths: env.paths)
        let pack = try makePack(env: env, updater: offline)

        await pack.refresh()

        XCTAssertEqual(pack.phase, .ready)
    }

    // MARK: Pause / resume / delete

    @MainActor
    func testPauseParksProgressAndResumeCompletesTheInstall() async throws {
        let env = try FingerprintUpdaterTestEnv.makeParts(partSize: 4096)
        env.remote.failAfterParts = 5      // stand in for a drop mid-transfer
        let pack = try makePack(env: env)
        pack.startDownload()
        await pack.waitForDownload()

        // A failure with bytes banked is a resume point, not a restart.
        XCTAssertTrue(pack.isPaused, "expected a resumable pause, got \(pack.phase)")
        let parked = try XCTUnwrap(pack.progress)
        XCTAssertGreaterThan(parked.bytesDone, 0)

        env.remote.failAfterParts = nil
        pack.startDownload()
        await pack.waitForDownload()

        XCTAssertEqual(pack.phase, .ready)
    }

    @MainActor
    func testGoingCellularMidDownloadAutoPauses() async throws {
        let env = try FingerprintUpdaterTestEnv.makeParts(partSize: 4096)
        let pack = try makePack(env: env)
        pack.startDownload()

        pack.networkChanged(isExpensive: true)

        XCTAssertEqual(pack.phase, .paused(pack.progress ?? .init(bytesDone: 0, totalBytes: 0), .cellular),
                       "a metered path must park the transfer, not spend the data")
        await pack.waitForDownload()
    }

    /// Device defect: "Download now" on the cellular confirmation must not be parked two seconds
    /// later by the very watcher that prompted it. Accepting a metered download means accepting it.
    @MainActor
    func testExplicitlyAcceptedCellularDownloadIsNotAutoPaused() async throws {
        let env = try FingerprintUpdaterTestEnv.makeParts(partSize: 4096)
        let pack = try makePack(env: env)
        pack.startDownload(allowingExpensive: true)

        pack.networkChanged(isExpensive: true)

        XCTAssertFalse(pack.isPaused, "the user already said yes to cellular for this transfer")
        await pack.waitForDownload()
        XCTAssertEqual(pack.phase, .ready)
    }

    /// ...but the consent is per-transfer: once installed, a later download must ask again.
    @MainActor
    func testCellularConsentDoesNotSurviveTheCompletedDownload() async throws {
        let env = try FingerprintUpdaterTestEnv.make()
        let pack = try makePack(env: env)
        pack.startDownload(allowingExpensive: true)
        await pack.waitForDownload()
        pack.deletePack()

        pack.startDownload()
        pack.networkChanged(isExpensive: true)

        XCTAssertTrue(pack.isPaused, "a fresh transfer must ask for cellular consent again")
        await pack.waitForDownload()
    }

    /// Device defect: consent used to accumulate, so a single "Download now" over cellular
    /// silenced the guard for every later download in the session — including one the user
    /// started expecting Wi-Fi-only behaviour.
    @MainActor
    func testCellularConsentDoesNotLeakIntoTheNextPausedResume() async throws {
        let env = try FingerprintUpdaterTestEnv.makeParts(partSize: 4096)
        env.remote.failAfterParts = 3
        let pack = try makePack(env: env)
        pack.startDownload(allowingExpensive: true)   // user accepted cellular once
        await pack.waitForDownload()
        XCTAssertTrue(pack.isPaused)

        env.remote.failAfterParts = nil
        pack.startDownload()                          // plain Resume — no new consent
        pack.networkChanged(isExpensive: true)

        XCTAssertEqual(pack.phase.pauseReason, .cellular,
                       "consent must not carry over into a transfer the user didn't approve")
        await pack.waitForDownload()
    }

    @MainActor
    func testNetworkChangeIgnoredWhenNothingIsDownloading() async throws {
        let env = try FingerprintUpdaterTestEnv.make()
        _ = try await env.updater.ensureLatest()
        let pack = try makePack(env: env)
        await pack.refresh()

        pack.networkChanged(isExpensive: true)

        XCTAssertEqual(pack.phase, .ready, "an installed pack is unaffected by going cellular")
    }

    /// The disk space had no way back before this: someone who has finished cataloguing and only
    /// wants to search was stuck carrying several hundred MB forever.
    @MainActor
    func testDeleteReclaimsTheSpaceAndReturnsToSetup() async throws {
        let env = try FingerprintUpdaterTestEnv.make()
        let pack = try makePack(env: env)
        pack.startDownload()
        await pack.waitForDownload()
        XCTAssertEqual(pack.phase, .ready)

        pack.deletePack()

        XCTAssertEqual(pack.phase, .notInstalled)
        XCTAssertNil(pack.installedVersion)
        XCTAssertNil(pack.installedBytes)
        XCTAssertNil(pack.matcher, "the sqlite handle must be dropped before the file goes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.paths.databaseURL.path))
        XCTAssertNil(env.updater.installedState())
    }

    @MainActor
    func testDeletedPackCanBeDownloadedAgain() async throws {
        let env = try FingerprintUpdaterTestEnv.make()
        let pack = try makePack(env: env)
        pack.startDownload()
        await pack.waitForDownload()
        pack.deletePack()

        pack.startDownload()
        await pack.waitForDownload()

        XCTAssertEqual(pack.phase, .ready)
        XCTAssertNotNil(pack.matcher)
    }

    @MainActor
    func testPublishedBytesComeFromTheManifestNotAHardcodedString() async throws {
        let env = try FingerprintUpdaterTestEnv.make()
        let pack = try makePack(env: env)

        await pack.refresh()

        XCTAssertEqual(pack.publishedBytes, env.gz.count)
    }
}
