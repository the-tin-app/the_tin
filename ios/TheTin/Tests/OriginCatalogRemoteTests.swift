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

final class OriginCatalogRemoteTests: XCTestCase {
    private let base = URL(string: "https://apithetin.reyes.ai")!

    private func manifestJSON(extra: [String: Any] = [:]) -> Data {
        var obj: [String: Any] = [
            "version": 7,
            "generatedAt": "2026-07-12T00:00:00.000Z",
            "tiers": [
                "casual":  ["path": "casual-v7.sqlite.gz",  "sha256": "cas", "sizeBytes": 11],
                "average": ["path": "average-v7.sqlite.gz", "sha256": "avg", "sizeBytes": 22],
                "expert":  ["path": "expert-v7.sqlite.gz",  "sha256": "exp", "sizeBytes": 33],
            ],
        ]
        obj.merge(extra) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testFetchManifestSelectsConfiguredTier() async throws {
        let http = PathHTTP()
        http.responses["/catalog/manifest.json"] = [(200, manifestJSON())]
        let remote = OriginCatalogRemote(baseURL: base, authorize: Authorizers.appAttest(TokenStub()), http: http, tier: "average")

        let m = try await remote.fetchManifest()
        XCTAssertEqual(m, CatalogManifest(version: 7, path: "average-v7.sqlite.gz", sha256: "avg",
                                          sizeBytes: 22, generatedAt: "2026-07-12T00:00:00.000Z",
                                          funding: nil, tier: "average"))
        XCTAssertEqual(http.sent.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
    }

    /// Regression: the NAS is the ONLY place `refresh-funding.ts` writes these blocks, and this
    /// remote used to hardcode `funding: nil` — leaving the nightly feed with no reader at all on
    /// the primary path.
    func testFetchManifestCarriesFundingAndSupporters() async throws {
        let http = PathHTTP()
        http.responses["/catalog/manifest.json"] = [(200, manifestJSON(extra: [
            "funding": ["fundedPct": 0.42, "monthlyGoalCents": 15000,
                        "raisedCents": 6300, "updatedAt": "2026-07-12T00:00:00.000Z"],
            "supporters": [["name": "Ada", "tier": "secret-rare", "url": "https://example.com"]],
        ]))]
        let remote = OriginCatalogRemote(baseURL: base, authorize: Authorizers.appAttest(TokenStub()), http: http, tier: "average")

        let m = try await remote.fetchManifest()
        XCTAssertEqual(m.funding?.raisedCents, 6300)
        XCTAssertEqual(m.funding?.monthlyGoalCents, 15000)
        XCTAssertEqual(m.supporters, [Supporter(name: "Ada", tier: "secret-rare", url: "https://example.com")])
    }

    /// Both blocks are absent until the nightly's step 7 has run against a live platform — that
    /// must stay a plain nil, not a decode failure that blocks catalog updates.
    func testFetchManifestWithoutFundingOrSupportersStillDecodes() async throws {
        let http = PathHTTP()
        http.responses["/catalog/manifest.json"] = [(200, manifestJSON())]
        let remote = OriginCatalogRemote(baseURL: base, authorize: Authorizers.appAttest(TokenStub()), http: http, tier: "average")
        let m = try await remote.fetchManifest()
        XCTAssertNil(m.funding)
        XCTAssertNil(m.supporters)
    }

    func testFetchManifestCasualTier() async throws {
        let http = PathHTTP()
        http.responses["/catalog/manifest.json"] = [(200, manifestJSON())]
        let remote = OriginCatalogRemote(baseURL: base, authorize: Authorizers.appAttest(TokenStub()), http: http, tier: "casual")
        let m = try await remote.fetchManifest()
        XCTAssertEqual(m.path, "casual-v7.sqlite.gz")
        XCTAssertEqual(m.sha256, "cas")
    }

    func testFetchDataPrefixesCatalogPathAndCarriesBearer() async throws {
        let http = PathHTTP()
        http.responses["/catalog/average-v7.sqlite.gz"] = [(200, Data("gz".utf8))]
        let remote = OriginCatalogRemote(baseURL: base, authorize: Authorizers.appAttest(TokenStub()), http: http, tier: "average")

        let data = try await remote.fetchData(path: "average-v7.sqlite.gz")
        XCTAssertEqual(data, Data("gz".utf8))
        XCTAssertEqual(http.sent.first?.url?.absoluteString, "https://apithetin.reyes.ai/catalog/average-v7.sqlite.gz")
        XCTAssertEqual(http.sent.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
    }

    /// An artifact is 26–179 MB and `timeoutInterval` is an IDLE timeout, so the manifest's 5 s
    /// aborted any download that stalled briefly on a home upstream — silently, because the edge
    /// had already sent its 200 with the headers. Nothing else observes this value, so without
    /// this assertion the regression is invisible until someone diffs served bytes against object
    /// size. Both must be checked in one test: the fix is that they DIFFER.
    func testArtifactGetsTheLongTimeoutAndTheManifestKeepsTheShortOne() async throws {
        let http = PathHTTP()
        http.responses["/catalog/average-v7.sqlite.gz"] = [(200, Data("gz".utf8))]
        http.responses["/catalog/manifest.json"] = [(200, manifestJSON())]
        let remote = OriginCatalogRemote(baseURL: base, authorize: Authorizers.appAttest(TokenStub()), http: http, tier: "average")

        _ = try await remote.fetchData(path: "average-v7.sqlite.gz")
        _ = try await remote.fetchManifest()

        XCTAssertEqual(http.sent[0].timeoutInterval, AppConfig.artifactTimeout)
        XCTAssertEqual(http.sent[1].timeoutInterval, AppConfig.selfHostTimeout)
        XCTAssertGreaterThan(AppConfig.artifactTimeout, AppConfig.selfHostTimeout)
    }

    /// The 401 retry rebuilds the request, so it is a second place the timeout can be dropped.
    func testTheRetryAfterA401KeepsTheArtifactTimeout() async throws {
        let http = PathHTTP()
        http.responses["/catalog/average-v7.sqlite.gz"] = [(401, Data()), (200, Data("gz".utf8))]
        let remote = OriginCatalogRemote(baseURL: base, authorize: Authorizers.appAttest(TokenStub()), http: http, tier: "average")

        _ = try await remote.fetchData(path: "average-v7.sqlite.gz")
        XCTAssertEqual(http.sent.count, 2)
        XCTAssertEqual(http.sent[1].timeoutInterval, AppConfig.artifactTimeout)
    }

    func test401RefreshesTokenAndRetriesOnce() async throws {
        let http = PathHTTP()
        http.responses["/catalog/average-v7.sqlite.gz"] = [(401, Data()), (200, Data("gz".utf8))]
        let session = TokenStub()
        let remote = OriginCatalogRemote(baseURL: base, authorize: Authorizers.appAttest(session), http: http, tier: "average")

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
        let remote = OriginCatalogRemote(baseURL: base, authorize: Authorizers.appAttest(TokenStub()), http: http, tier: "average")
        do { _ = try await remote.fetchData(path: "average-v7.sqlite.gz"); XCTFail("expected throw") }
        catch let e as CatalogError { XCTAssertEqual(e, .httpStatus(404)) }
        catch { XCTFail("wrong error") }
    }
}
