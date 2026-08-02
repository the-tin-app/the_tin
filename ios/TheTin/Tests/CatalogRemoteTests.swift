import XCTest
@testable import TheTin

/// `OriginCatalogRemote` is the one remote type left: it serves both the self-hosted NAS (App
/// Attest) and the R2 backup (App Check), differing only in the `authorize` closure it's given.
/// The old bucket-REST fallback remote, with its own URL-encoding scheme, was deleted in Task 7
/// — R2 serves ordinary paths through a Cloudflare Worker instead.
final class CatalogRemoteTests: XCTestCase {
    func testOriginRemoteSendsWhateverHeaderTheAuthorizerSets() async throws {
        let http = RecordingHTTPClient(status: 200, body: Data("{}".utf8))
        let remote = OriginCatalogRemote(
            baseURL: URL(string: "https://backup.example")!,
            authorize: { req, _ in req.setValue("tok", forHTTPHeaderField: "X-Firebase-AppCheck") },
            http: http)
        _ = try? await remote.fetchData(path: "manifest.json")
        XCTAssertEqual(http.lastRequest?.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "tok")
        XCTAssertNil(http.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(http.lastRequest?.url?.absoluteString, "https://backup.example/catalog/manifest.json")
    }

    func testOriginRemoteReauthorizesOnceAfterA401() async throws {
        let http = RecordingHTTPClient(statuses: [401, 200], body: Data("{}".utf8))
        var refreshes = 0
        let remote = OriginCatalogRemote(
            baseURL: URL(string: "https://backup.example")!,
            authorize: { req, refresh in
                if refresh { refreshes += 1 }
                req.setValue(refresh ? "fresh" : "stale", forHTTPHeaderField: "X-Firebase-AppCheck")
            },
            http: http)
        _ = try await remote.fetchData(path: "manifest.json")
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(http.lastRequest?.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "fresh")
    }

    /// Pins the `FirebaseApp.app() != nil` guard in `StorageAuth.appCheckToken`, the guard the
    /// doc comment says is load-bearing: `AppCheck.appCheck()` raises an uncaught NSException —
    /// not a catchable Swift error — when the default app isn't configured, and this whole test
    /// host never configures one (`TheTin.swift`'s `isTesting` → `skipFirebase: true`). This is
    /// the real function `Authorizers.appCheck()` calls to authorize every R2 request, unlike the
    /// deleted `authorizedRequest(url:)` this test used to pin instead.
    func testAppCheckTokenGuardsUnconfiguredFirebaseWithoutCrashing() async throws {
        let token = await StorageAuth.appCheckToken(forcingRefresh: false)
        XCTAssertNil(token)
    }
}

final class RecordingHTTPClient: HTTPClient, @unchecked Sendable {
    private var statuses: [Int]
    private let body: Data
    private(set) var lastRequest: URLRequest?

    init(status: Int, body: Data) { self.statuses = [status]; self.body = body }
    init(statuses: [Int], body: Data) { self.statuses = statuses; self.body = body }

    func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = req
        let code = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        return (body, HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }

    func send(_ req: URLRequest, onBytes: @escaping @Sendable (Int) -> Void) async throws -> (Data, HTTPURLResponse) {
        try await send(req)
    }
}
