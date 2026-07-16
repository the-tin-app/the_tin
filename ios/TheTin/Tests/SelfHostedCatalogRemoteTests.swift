import XCTest
@testable import TheTin

private final class TokenStub: SessionProvider {
    var tokens = ["fresh", "refreshed"]
    private(set) var refreshes = 0
    func authToken() async throws -> String { tokens[0] }
    func refreshedToken() async throws -> String { refreshes += 1; return tokens[1] }
}

private final class PathHTTP: HTTPClient {
    var responses: [String: [(Int, Data)]] = [:]     // path -> queued (status, body)
    private(set) var sent: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        let path = request.url!.path
        guard var q = responses[path], !q.isEmpty else { throw CatalogError.httpStatus(599) }
        let (status, data) = q.removeFirst(); responses[path] = q
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class SelfHostedCatalogRemoteTests: XCTestCase {
    private let base = URL(string: "https://apithetin.reyes.ai")!

    private func manifestJSON() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "version": 7,
            "generatedAt": "2026-07-12T00:00:00.000Z",
            "tiers": [
                "casual":  ["path": "casual-v7.sqlite.gz",  "sha256": "cas", "sizeBytes": 11],
                "average": ["path": "average-v7.sqlite.gz", "sha256": "avg", "sizeBytes": 22],
                "expert":  ["path": "expert-v7.sqlite.gz",  "sha256": "exp", "sizeBytes": 33],
            ],
        ])
    }

    func testFetchManifestSelectsConfiguredTier() async throws {
        let http = PathHTTP()
        http.responses["/catalog/manifest.json"] = [(200, manifestJSON())]
        let remote = SelfHostedCatalogRemote(baseURL: base, session: TokenStub(), http: http, tier: "average")

        let m = try await remote.fetchManifest()
        XCTAssertEqual(m, CatalogManifest(version: 7, path: "average-v7.sqlite.gz", sha256: "avg",
                                          sizeBytes: 22, generatedAt: "2026-07-12T00:00:00.000Z",
                                          funding: nil, tier: "average"))
        XCTAssertEqual(http.sent.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
    }

    func testFetchManifestCasualTier() async throws {
        let http = PathHTTP()
        http.responses["/catalog/manifest.json"] = [(200, manifestJSON())]
        let remote = SelfHostedCatalogRemote(baseURL: base, session: TokenStub(), http: http, tier: "casual")
        let m = try await remote.fetchManifest()
        XCTAssertEqual(m.path, "casual-v7.sqlite.gz")
        XCTAssertEqual(m.sha256, "cas")
    }

    func testFetchDataPrefixesCatalogPathAndCarriesBearer() async throws {
        let http = PathHTTP()
        http.responses["/catalog/average-v7.sqlite.gz"] = [(200, Data("gz".utf8))]
        let remote = SelfHostedCatalogRemote(baseURL: base, session: TokenStub(), http: http, tier: "average")

        let data = try await remote.fetchData(path: "average-v7.sqlite.gz")
        XCTAssertEqual(data, Data("gz".utf8))
        XCTAssertEqual(http.sent.first?.url?.absoluteString, "https://apithetin.reyes.ai/catalog/average-v7.sqlite.gz")
        XCTAssertEqual(http.sent.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
    }

    func test401RefreshesTokenAndRetriesOnce() async throws {
        let http = PathHTTP()
        http.responses["/catalog/average-v7.sqlite.gz"] = [(401, Data()), (200, Data("gz".utf8))]
        let session = TokenStub()
        let remote = SelfHostedCatalogRemote(baseURL: base, session: session, http: http, tier: "average")

        let data = try await remote.fetchData(path: "average-v7.sqlite.gz")
        XCTAssertEqual(data, Data("gz".utf8))
        XCTAssertEqual(session.refreshes, 1)
        XCTAssertEqual(http.sent.count, 2)
        XCTAssertEqual(http.sent[0].value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        XCTAssertEqual(http.sent[1].value(forHTTPHeaderField: "Authorization"), "Bearer refreshed")
    }

    func testNon401ErrorDoesNotRetry() async {
        let http = PathHTTP()
        http.responses["/catalog/average-v7.sqlite.gz"] = [(404, Data())]
        let remote = SelfHostedCatalogRemote(baseURL: base, session: TokenStub(), http: http, tier: "average")
        do { _ = try await remote.fetchData(path: "average-v7.sqlite.gz"); XCTFail("expected throw") }
        catch let e as CatalogError { XCTAssertEqual(e, .httpStatus(404)) }
        catch { XCTFail("wrong error") }
    }
}
