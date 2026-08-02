import XCTest
@testable import TheTin

/// The catalog is served publicly via the Firebase Storage rules layer (the org blocks public
/// GCS buckets), which requires the Firebase Storage download endpoint URL format:
/// `https://firebasestorage.googleapis.com/v0/b/<bucket>/o/<percent-encoded-object-path>?alt=media`.
/// The object path is ONE encoded segment after `/o/` — every `/` in it must become `%2F`.
final class CatalogRemoteTests: XCTestCase {
    func testDownloadURLEncodesManifestPath() throws {
        let url = try XCTUnwrap(HTTPCatalogRemote.downloadURL(base: AppConfig.catalogBaseURL, path: "catalog/manifest.json"))
        XCTAssertEqual(
            url.absoluteString,
            "https://firebasestorage.googleapis.com/v0/b/hobby-tcg.firebasestorage.app/o/catalog%2Fmanifest.json?alt=media"
        )
    }

    func testDownloadURLEncodesArtifactPath() throws {
        let url = try XCTUnwrap(HTTPCatalogRemote.downloadURL(base: AppConfig.catalogBaseURL, path: "catalog/catalog-v1.sqlite.gz"))
        XCTAssertEqual(
            url.absoluteString,
            "https://firebasestorage.googleapis.com/v0/b/hobby-tcg.firebasestorage.app/o/catalog%2Fcatalog-v1.sqlite.gz?alt=media"
        )
    }

    func testDownloadURLEncodesNestedDeltaPath() throws {
        let url = try XCTUnwrap(HTTPCatalogRemote.downloadURL(base: AppConfig.catalogBaseURL, path: "catalog/deltas/prices-2026-07-06.json.gz"))
        XCTAssertEqual(
            url.absoluteString,
            "https://firebasestorage.googleapis.com/v0/b/hobby-tcg.firebasestorage.app/o/catalog%2Fdeltas%2Fprices-2026-07-06.json.gz?alt=media"
        )
    }

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
