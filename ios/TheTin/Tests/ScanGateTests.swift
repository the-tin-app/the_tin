import XCTest
@testable import TheTin

/// Simulates the self-hosted server rejecting the device (e.g. App Attest env mismatch):
/// every call fails auth, exactly what a production build sees against a dev-mode server.
private struct RejectingFPRemote: FingerprintRemote {
    func fetchManifest() async throws -> FingerprintManifest { throw CatalogError.httpStatus(401) }
    func fetchData(path: String) async throws -> Data { throw CatalogError.httpStatus(401) }
}

final class ScanGateTests: XCTestCase {
    /// Mirrors the catalog's whole-operation failover: when the self-hosted pack download
    /// fails (dev-mode server rejecting prod App Attest), the gate must retry the entire
    /// update against the Firebase fallback instead of stranding on "Download failed".
    @MainActor
    func testDownloadFailsOverToFallbackUpdater() async throws {
        let env = try FingerprintUpdaterTestEnv.make()   // working remote → the fallback
        let primary = FingerprintUpdater(remote: RejectingFPRemote(), paths: env.paths)
        let gate = ScanGateModel(updater: primary, fallbackUpdater: env.updater,
                                 paths: env.paths, catalogStore: try FixtureCatalog.make(),
                                 makeStore: env.makeStore,
                                 makeCodebook: { try Codebook.bundled(in: Bundle(for: Self.self)) })
        await gate.check()
        XCTAssertEqual(gate.state, .needsDownload)
        await gate.download()
        XCTAssertEqual(gate.state, .ready)
        for _ in 0..<20 where gate.downloadPercent < 100 { await Task.yield() }
        XCTAssertEqual(gate.downloadPercent, 100,
                       "the downloading UI needs progress even on the fallback path")
    }

    /// No fallback configured (Firebase-only wiring): a failed download must still surface
    /// the retryable error state, not crash or spin.
    @MainActor
    func testDownloadFailureWithoutFallbackIsUnavailable() async throws {
        let env = try FingerprintUpdaterTestEnv.make()
        let primary = FingerprintUpdater(remote: RejectingFPRemote(), paths: env.paths)
        let gate = ScanGateModel(updater: primary, paths: env.paths, catalogStore: try FixtureCatalog.make(),
                                 makeStore: env.makeStore,
                                 makeCodebook: { try Codebook.bundled(in: Bundle(for: Self.self)) })
        await gate.download()
        XCTAssertEqual(gate.state, .unavailable("Download failed. Check Wi-Fi and try again."))
    }
    @MainActor
    func testMissingPackRequiresDownloadThenReady() async throws {
        // FakeFingerprintRemote/paths already exist from FingerprintUpdaterTests — reuse them.
        let env = try FingerprintUpdaterTestEnv.make()   // temp paths + fake remote, no installed pack
        let gate = ScanGateModel(updater: env.updater, paths: env.paths, catalogStore: try FixtureCatalog.make(),
                                 makeStore: env.makeStore,
                                 makeCodebook: { try Codebook.bundled(in: Bundle(for: Self.self)) })
        await gate.check()
        XCTAssertEqual(gate.state, .needsDownload)
        await gate.download()
        XCTAssertEqual(gate.state, .ready)
    }

    /// Regression guard for Findings 1+2: a pack file that EXISTS but can't be opened
    /// (corrupt/truncated/garbage bytes) must never crash the process, and must never
    /// leave `check()` reporting `.ready` with a nil matcher (which would strand the UI
    /// behind a `ProgressView()` forever). It must land on `.unavailable`.
    @MainActor
    func testPresentButUnopenablePackDegradesToUnavailable() async throws {
        let env = try FingerprintUpdaterTestEnv.make()
        // Simulate an installed-AND-current but corrupt pack: matching state.json (so the
        // freshness check reports current, not stale→needsDownload) + garbage where the
        // sqlite pack is expected, so fileExists is true but FingerprintStore can't open it.
        try env.updater.saveState(FingerprintState(version: 1, fpVersion: 1,
                                                   codebookHash: FingerprintUpdaterTestEnv.goodHash))
        try Data("not a sqlite database".utf8).write(to: env.paths.databaseURL)

        let gate = ScanGateModel(updater: env.updater, paths: env.paths, catalogStore: try FixtureCatalog.make(),
                                 makeStore: env.makeStore,
                                 makeCodebook: { try Codebook.bundled(in: Bundle(for: Self.self)) })
        await gate.check() // must not crash

        XCTAssertEqual(gate.state, .unavailable("Scanner data unavailable."))
        XCTAssertNil(gate.matcher)
        XCTAssertNil(gate.index)
    }
}
