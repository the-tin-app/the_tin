import XCTest
import CryptoKit
import Gzip
import GRDB
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
        XCTAssertEqual(try model.store?.cardCount(), 7)
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
        XCTAssertEqual(try offline.store?.cardCount(), 7)
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
        XCTAssertEqual(try model.store?.cardCount(), 7) // throws "disk I/O error" without the reopen
        XCTAssertFalse(try XCTUnwrap(model.store).sets().isEmpty)
    }

    /// End-to-end replay of the 2026-07-18 incident with two synthetic artifacts: a transient
    /// primary failure mid-session must NOT let the casual-only fallback replace the installed
    /// average catalog (history would vanish) — and when the primary recovers with a newer
    /// version, the update installs and the in-place-reopened store serves history again.
    func testPrimaryBlipDoesNotDowngradeAndRecoveryStillUpdates() async throws {
        let paths = tempPaths()

        // Install v14 "average" — the fixture as-is, which has price_history rows.
        let seed = AppModel(remote: try stubRemoteWithFixture(version: 14, tier: "average"),
                            paths: paths,
                            makeRepository: { _ in InMemoryCollectionRepository() },
                            skipFirebase: true)
        await seed.start()
        XCTAssertEqual(seed.catalogState?.tier, "average")
        XCTAssertFalse(try XCTUnwrap(seed.store).priceHistory(cardId: "swsh7-215").isEmpty)

        // v14 "casual" — same fixture with price_history emptied, like the Firebase backup.
        let casualPath = try FixtureCatalog.copyToTemp()
        try Self.emptyPriceHistory(atPath: casualPath)
        let casualGz = try Data(contentsOf: URL(fileURLWithPath: casualPath)).gzipped()
        let casualSha = SHA256.hash(data: casualGz).map { String(format: "%02x", $0) }.joined()
        let casualManifest = CatalogManifest(version: 14, path: "catalog/catalog-v14c.sqlite.gz",
                                             sha256: casualSha, sizeBytes: casualGz.count,
                                             generatedAt: "2026-07-18T07:00:00.000Z", tier: "casual")
        let casual = StubRemote(manifest: casualManifest)
        casual.files[casualManifest.path] = casualGz

        // Relaunch with the primary dead: the whole refresh falls back to casual v14.
        let toggle = ToggleRemote()
        var nowValue = Date()
        let model = AppModel(remote: toggle, fallback: casual, paths: paths,
                             makeRepository: { _ in InMemoryCollectionRepository() },
                             skipFirebase: true, now: { nowValue })
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        for _ in 0..<200 where model.lastRefreshCheck == nil { // launch refresh is fire-and-forget
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // The guard held: still average v14, history still served — NOT casual's empty table.
        XCTAssertEqual(model.catalogState?.version, 14)
        XCTAssertEqual(model.catalogState?.tier, "average")
        XCTAssertFalse(try XCTUnwrap(model.store).priceHistory(cardId: "swsh7-215").isEmpty)
        XCTAssertFalse(model.reducedData)

        // Primary recovers with v15 average: the throttled foreground refresh installs it and
        // the same store instance serves the new artifact (funneled reopen).
        toggle.inner = try stubRemoteWithFixture(version: 15, tier: "average")
        nowValue += 7200
        let storeBefore = try XCTUnwrap(model.store)
        await model.refreshIfStale()
        XCTAssertEqual(model.catalogState?.version, 15)
        XCTAssertEqual(model.catalogState?.tier, "average")
        XCTAssertTrue(model.store === storeBefore)
        XCTAssertFalse(try storeBefore.priceHistory(cardId: "swsh7-215").isEmpty)
    }

    /// Sync helper so GRDB's synchronous `write` overload is picked (the async test body
    /// otherwise resolves to the async one).
    private nonisolated static func emptyPriceHistory(atPath path: String) throws {
        let db = try DatabaseQueue(path: path)
        try db.write { try $0.execute(sql: "DELETE FROM price_history") }
        try db.close()
    }

    /// Primary remote that plays dead until given an inner remote — models a NAS blip.
    private final class ToggleRemote: CatalogRemote {
        var inner: CatalogRemote?
        func fetchManifest() async throws -> CatalogManifest {
            guard let inner else { throw CatalogError.httpStatus(500) }
            return try await inner.fetchManifest()
        }
        func fetchData(path: String) async throws -> Data {
            guard let inner else { throw CatalogError.httpStatus(500) }
            return try await inner.fetchData(path: path)
        }
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
        XCTAssertEqual(try storeAtLaunch.cardCount(), 7) // the held instance serves the new artifact
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
        XCTAssertEqual(try storeAtLaunch.cardCount(), 7)

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
        let selfHost = OriginCatalogRemote(baseURL: URL(string: "https://apithetin.reyes.ai")!,
                                           authorize: Authorizers.appAttest(StubSession()), http: FailHTTP(), tier: "average")
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

        let selfHost = OriginCatalogRemote(baseURL: URL(string: "https://apithetin.reyes.ai")!,
                                           authorize: Authorizers.appAttest(StubSession()), http: FailHTTP(), tier: "average")
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

    // MARK: - R2 backup source labelling (Task 7)

    /// Pin `AppConfig.catalogTier` in BOTH directions: several tests in this section depend on
    /// its value at `AppModel` construction (`currentTier` snapshots it in a property
    /// initializer), and a persisted UserDefaults key must never leak into a different test on
    /// the NEXT run.
    private var savedCatalogTierForBackupTests: String!

    override func setUpWithError() throws {
        savedCatalogTierForBackupTests = AppConfig.catalogTier
    }

    override func tearDownWithError() throws {
        AppConfig.catalogTier = savedCatalogTierForBackupTests
    }

    /// Manifest+HTTP fake that actually serves the NAS/R2 tiered SHAPE through a REAL
    /// `OriginCatalogRemote` — unlike `StubRemote` (a plain `CatalogRemote` fake, never an
    /// `OriginCatalogRemote`), which cannot reproduce the type-sniff bug below: sniffing on a
    /// `StubRemote` primary always lands on the "not OriginCatalogRemote" branch regardless of
    /// whether the sniff is present, so it can never fail either way. Only a primary that IS an
    /// `OriginCatalogRemote` — the exact shape both the self-host AND R2-primary-only production
    /// paths use — can distinguish "explicit `primarySource`" from "sniffed by type".
    private struct FixtureOriginHTTP: HTTPClient {
        let manifestJSON: Data
        let artifactGz: Data
        func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let body = req.url?.lastPathComponent == "manifest.json" ? manifestJSON : artifactGz
            return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        func send(_ req: URLRequest, onBytes: @escaping @Sendable (Int) -> Void) async throws -> (Data, HTTPURLResponse) {
            try await send(req)
        }
    }

    private func originRemoteWithFixture(tier: String = "expert") throws -> OriginCatalogRemote {
        let sqlite = try Data(contentsOf: URL(fileURLWithPath: try FixtureCatalog.copyToTemp()))
        let gz = try sqlite.gzipped()
        let sha = SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined()
        let entry = "{\"path\":\"fixture-v1.sqlite.gz\",\"sha256\":\"\(sha)\",\"sizeBytes\":\(gz.count)}"
        let manifestJSON = Data("""
        {"version":1,"generatedAt":"2026-07-04T09:00:00.000Z",
         "tiers":{"casual":\(entry),"average":\(entry),"expert":\(entry)}}
        """.utf8)
        let http = FixtureOriginHTTP(manifestJSON: manifestJSON, artifactGz: gz)
        return OriginCatalogRemote(baseURL: URL(string: "https://backup.example")!,
                                   authorize: { _, _ in }, http: http, tier: tier)
    }

    func testFallbackIsLabelledBackupNotSelfHosted() async throws {
        // The type-sniff this task removed lived on the PRIMARY-SUCCESS line
        // (`remote is OriginCatalogRemote ? .selfHosted : <the old fallback label>`), not the
        // fallback branch — a fallback-branch test sets `.backup` as a literal and never
        // exercises the sniff at all
        // (proven by mutation: restoring the sniff on the primary line left the OLD version of
        // this test green — 14/14 passed). Pin it with a SUCCEEDING primary that both IS an
        // `OriginCatalogRemote` (the only way a surviving sniff can misfire) and is explicitly
        // `.backup` — the exact shape `makeDefault`'s no-self-host branch builds
        // (`backupRemote()` IS an `OriginCatalogRemote`), where a surviving sniff would mislabel
        // a pure-R2 session "Self-hosted" and hide the backup footer.
        let model = AppModel(remote: try originRemoteWithFixture(), primarySource: .backup,
                             paths: tempPaths(), skipFirebase: true)
        await model.start()
        XCTAssertEqual(model.activeSource, .backup)
    }

    /// Negative control for the test below: proves `reducedData` CAN be true, so a `false` result
    /// there is actually discriminating rather than unsatisfiable for every tier (as it was when
    /// this test asserted `expert`, the maximum of `CatalogTier.allCases`, against every possible
    /// `currentTier`). If a casual stamp ever reappears on the backup — the exact bug the old,
    /// now-deleted bucket-REST fallback's "untiered ⇒ casual" default used to cause — this fails.
    func testCasualBackupTriggersReducedDataBanner() async throws {
        AppConfig.catalogTier = CatalogTier.expert.rawValue
        let model = AppModel(remote: DeadRemote(),
                             fallback: try stubRemoteWithFixture(version: 30, tier: "casual"),
                             paths: tempPaths(), skipFirebase: true)
        await model.start()
        XCTAssertEqual(model.catalogState?.tier, "casual")
        XCTAssertTrue(model.reducedData)
    }

    func testBackupServesTheUsersOwnTierNotCasual() async throws {
        // The whole point of putting all three tiers on R2: failover must install the tier the
        // user actually chose, not silently downgrade it — pinned against the exact tier chosen
        // rather than an unfalsifiable "reducedData is false" check.
        AppConfig.catalogTier = CatalogTier.expert.rawValue
        let model = AppModel(remote: DeadRemote(),
                             fallback: try stubRemoteWithFixture(version: 30, tier: "expert"),
                             paths: tempPaths(), skipFirebase: true)
        await model.start()
        XCTAssertEqual(model.catalogState?.tier, "expert")
        XCTAssertFalse(model.reducedData)
    }
}

private extension ISO8601DateFormatter {
    static let fundingTestFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
