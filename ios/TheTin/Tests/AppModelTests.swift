import XCTest
import CryptoKit
import Gzip
@testable import TheTin

@MainActor
final class AppModelTests: XCTestCase {
    private func stubRemoteWithFixture(version: Int = 1, tier: String? = nil) throws -> StubRemote {
        let sqlite = try Data(contentsOf: URL(fileURLWithPath: try FixtureCatalog.copyToTemp()))
        let gz = try sqlite.gzipped()
        let sha = SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined()
        let manifest = CatalogManifest(version: version, path: "catalog/catalog-v\(version).sqlite.gz",
                                       sha256: sha, sizeBytes: gz.count,
                                       generatedAt: "2026-07-04T09:00:00.000Z", tier: tier)
        let remote = StubRemote(manifest: manifest)
        remote.files[manifest.path] = gz
        return remote
    }

    private func tempPaths() -> CatalogPaths {
        CatalogPaths(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
    }

    private final class DeadRemote: CatalogRemote {
        func fetchManifest() async throws -> CatalogManifest { throw CatalogError.httpStatus(500) }
        func fetchData(path: String) async throws -> Data { throw CatalogError.httpStatus(500) }
    }

    func testFirstRunDownloadsCatalogAndBecomesReady() async throws {
        let model = AppModel(remote: try stubRemoteWithFixture(), paths: tempPaths(),
                             makeRepository: { _ in InMemoryCollectionRepository() },
                             skipFirebase: true)
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNotNil(model.store)
        XCTAssertNotNil(model.collection)
        XCTAssertEqual(model.catalogState?.version, 1)
        XCTAssertEqual(try model.store?.cardCount(), 6)
    }

    func testFailedManifestOnFirstRunIsRetryable() async throws {
        final class DeadRemote: CatalogRemote {
            func fetchManifest() async throws -> CatalogManifest { throw CatalogError.httpStatus(500) }
            func fetchData(path: String) async throws -> Data { throw CatalogError.httpStatus(500) }
        }
        let model = AppModel(remote: DeadRemote(), paths: tempPaths(),
                             makeRepository: { _ in InMemoryCollectionRepository() },
                             skipFirebase: true)
        await model.start()
        guard case .failed = model.phase else {
            return XCTFail("expected .failed, got \(model.phase)")
        }
    }

    func testSecondRunOpensInstalledCatalogWithoutNetwork() async throws {
        let paths = tempPaths()
        let good = AppModel(remote: try stubRemoteWithFixture(), paths: paths,
                            makeRepository: { _ in InMemoryCollectionRepository() },
                            skipFirebase: true)
        await good.start()
        XCTAssertEqual(good.phase, .ready)

        final class DeadRemote: CatalogRemote {
            func fetchManifest() async throws -> CatalogManifest { throw URLError(.notConnectedToInternet) }
            func fetchData(path: String) async throws -> Data { throw URLError(.notConnectedToInternet) }
        }
        let offline = AppModel(remote: DeadRemote(), paths: paths,
                               makeRepository: { _ in InMemoryCollectionRepository() },
                               skipFirebase: true)
        await offline.start()
        XCTAssertEqual(offline.phase, .ready) // offline-first: installed catalog is enough
        XCTAssertEqual(try offline.store?.cardCount(), 6)
    }

    /// A new version published while the app runs (nightly pipeline) installs mid-session via
    /// `backgroundRefresh`. The swap kills the open store's WAL connection, so the session must
    /// reopen it — otherwise every read throws "disk I/O error" and the UI renders empty lists
    /// until the next launch (the 2026-07-14 morning-after-nightly bug).
    func testMidSessionInstallReopensStoreAndServesData() async throws {
        let paths = tempPaths()
        let first = AppModel(remote: try stubRemoteWithFixture(), paths: paths,
                             makeRepository: { _ in InMemoryCollectionRepository() },
                             skipFirebase: true)
        await first.start()
        XCTAssertEqual(first.catalogState?.version, 1)

        // Next launch: opens installed v1 offline-first, then backgroundRefresh finds v2.
        let model = AppModel(remote: try stubRemoteWithFixture(version: 2), paths: paths,
                             makeRepository: { _ in InMemoryCollectionRepository() },
                             skipFirebase: true)
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        for _ in 0..<200 where model.catalogState?.version != 2 { // backgroundRefresh is fire-and-forget
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(model.catalogState?.version, 2)
        XCTAssertEqual(try model.store?.cardCount(), 6) // throws "disk I/O error" without the reopen
        XCTAssertFalse(try XCTUnwrap(model.store).sets().isEmpty)
    }

    /// Views and models (DiscoverModel, SearchModel, CollectionModel…) capture the CatalogStore
    /// instance at creation and are never rebuilt mid-session — so the post-install reopen must
    /// happen IN PLACE on the same instance. A replacement instance leaves them querying a
    /// closed handle (the 2026-07-16 dead Discover tab).
    func testMidSessionInstallKeepsStoreInstanceAlive() async throws {
        let paths = tempPaths()
        let first = AppModel(remote: try stubRemoteWithFixture(), paths: paths,
                             makeRepository: { _ in InMemoryCollectionRepository() },
                             skipFirebase: true)
        await first.start()

        let model = AppModel(remote: try stubRemoteWithFixture(version: 2), paths: paths,
                             makeRepository: { _ in InMemoryCollectionRepository() },
                             skipFirebase: true)
        await model.start()
        let storeAtLaunch = try XCTUnwrap(model.store)
        for _ in 0..<200 where model.catalogState?.version != 2 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(model.catalogState?.version, 2)
        XCTAssertTrue(model.store === storeAtLaunch, "reopen must reuse the instance views hold")
        XCTAssertEqual(try storeAtLaunch.cardCount(), 6) // the held instance serves the new artifact
    }

    /// The daily catalog usually publishes while the app sits suspended. Foregrounding calls
    /// `refreshIfStale()`, which applies the new version (in place) — but is throttled, so a
    /// second foreground minutes later doesn't re-fetch.
    func testForegroundRefreshAppliesNewVersionAndThrottles() async throws {
        let paths = tempPaths()
        let remote = try stubRemoteWithFixture(version: 1)
        var nowValue = Date()
        let model = AppModel(remote: remote, paths: paths,
                             makeRepository: { _ in InMemoryCollectionRepository() },
                             skipFirebase: true, now: { nowValue })
        await model.start()
        for _ in 0..<200 where model.lastRefreshCheck == nil { // launch refresh is fire-and-forget
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let storeAtLaunch = try XCTUnwrap(model.store)

        // Nightly pipeline publishes v2 while the app is suspended; user foregrounds 2h later.
        let v2 = try stubRemoteWithFixture(version: 2)
        remote.manifest = v2.manifest
        remote.files = v2.files
        nowValue += 7200
        await model.refreshIfStale()
        XCTAssertEqual(model.catalogState?.version, 2)
        XCTAssertTrue(model.store === storeAtLaunch)
        XCTAssertEqual(try storeAtLaunch.cardCount(), 6)

        // v3 appears, but the next foreground is within the hour — throttled, no fetch.
        let v3 = try stubRemoteWithFixture(version: 3)
        remote.manifest = v3.manifest
        remote.files = v3.files
        nowValue += 60
        await model.refreshIfStale()
        XCTAssertEqual(model.catalogState?.version, 2)
    }

    // MARK: - Funding

    /// Fixed clock so `updatedAt` timestamps below are deterministically "fresh" (well under the
    /// 48h staleness cap tested separately in FundingModelTests).
    private let fixedNow = ISO8601DateFormatter.fundingTestFormatter.date(from: "2026-07-05T12:00:00.000Z")!

    private func stubRemote(funding: FundingSnapshot) throws -> StubRemote {
        let sqlite = try Data(contentsOf: URL(fileURLWithPath: try FixtureCatalog.copyToTemp()))
        let gz = try sqlite.gzipped()
        let sha = SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined()
        let manifest = CatalogManifest(version: 1, path: "catalog/catalog-v1.sqlite.gz",
                                       sha256: sha, sizeBytes: gz.count,
                                       generatedAt: "2026-07-04T09:00:00.000Z",
                                       funding: funding)
        let remote = StubRemote(manifest: manifest)
        remote.files[manifest.path] = gz
        return remote
    }

    /// Funding is now display-only (no gate, no punishing state copy): the manifest snapshot's
    /// progress values surface verbatim regardless of state.
    func testFundingSnapshotSurfacesAsProgress() async throws {
        let funding = FundingSnapshot(state: .yellow, fundedPct: 0.62, monthlyGoalCents: 15_000,
                                       raisedCents: 9_300, updatedAt: "2026-07-05T11:00:00.000Z")
        let model = AppModel(remote: try stubRemote(funding: funding), paths: tempPaths(),
                             makeRepository: { _ in InMemoryCollectionRepository() },
                             skipFirebase: true, now: { self.fixedNow })
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.funding.fundedPct, 0.62, accuracy: 0.0001)
        XCTAssertEqual(model.funding.monthlyGoalCents, 15_000)
        XCTAssertEqual(model.funding.raisedCents, 9_300)
    }

    // MARK: - Operation-level failover

    func testCatalogUpdateFailsOverToFallbackSource() async throws {
        // Primary source throws for the whole update; the Firebase fallback serves it.
        let model = AppModel(remote: DeadRemote(), fallback: try stubRemoteWithFixture(),
                             paths: tempPaths(), skipFirebase: true)
        await model.start()
        XCTAssertEqual(model.phase, .ready)
    }

    func testPrimarySuccessDoesNotConsultFallback() async throws {
        // Primary serves; the fallback is a DeadRemote that would fail if consulted.
        let model = AppModel(remote: try stubRemoteWithFixture(), fallback: DeadRemote(),
                             paths: tempPaths(), skipFirebase: true)
        await model.start()
        XCTAssertEqual(model.phase, .ready)
    }

    private struct FailHTTP: HTTPClient {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw CatalogError.httpStatus(599)
        }
    }

    private struct StubSession: SessionProvider {
        func authToken() async throws -> String { "t" }
        func refreshedToken() async throws -> String { "t" }
    }

    func testSelfHostTierUnreachableFallsBackToFirebaseCasual() async throws {
        // "NAS down": a real self-hosted remote whose HTTP layer always fails. The Firebase
        // fallback serves the casual catalog and the whole update still reaches .ready.
        let selfHost = SelfHostedCatalogRemote(baseURL: URL(string: "https://apithetin.reyes.ai")!,
                                               session: StubSession(), http: FailHTTP(), tier: "average")
        let model = AppModel(remote: selfHost, fallback: try stubRemoteWithFixture(),
                             paths: tempPaths(), skipFirebase: true)
        await model.start()
        XCTAssertEqual(model.phase, .ready)
    }

    func testSetTierServedByCasualFallbackReportsMismatchNotDone() async throws {
        // NAS rejects the device, so the whole op lands on the casual-only fallback. A tier
        // switch to average must NOT report .done — the installed bytes are still casual.
        let saved = AppConfig.catalogTier
        defer { AppConfig.catalogTier = saved }
        AppConfig.catalogTier = CatalogTier.casual.rawValue

        let selfHost = SelfHostedCatalogRemote(baseURL: URL(string: "https://apithetin.reyes.ai")!,
                                               session: StubSession(), http: FailHTTP(), tier: "average")
        let model = AppModel(remote: selfHost,
                             fallback: try stubRemoteWithFixture(tier: CatalogTier.casual.rawValue),
                             paths: tempPaths(), skipFirebase: true)
        await model.start()
        XCTAssertEqual(model.catalogState?.tier, "casual")

        await model.setTier(.average)
        XCTAssertEqual(model.catalogState?.tier, "casual")
        guard case .failed(let msg) = model.tierChange else {
            return XCTFail("expected .failed, got \(model.tierChange)")
        }
        XCTAssertTrue(msg.contains("backup source"), msg)
    }
}

private extension ISO8601DateFormatter {
    static let fundingTestFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
