import XCTest
import CryptoKit
@testable import TheTin

private final class FakeAttestor: Attestor {
    var isSupported = true
    var appleKeyId = "QUJD"                     // base64 for "ABC"
    private(set) var attestHashes: [Data] = []
    private(set) var assertHashes: [Data] = []
    func generateKey() async throws -> String { appleKeyId }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        attestHashes.append(clientDataHash); return Data("attestation".utf8)
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        assertHashes.append(clientDataHash); return Data("assertion".utf8)
    }
}

private final class InMemoryKV: KeyValueStore {
    var storage: [String: String] = [:]
    func get(_ key: String) -> String? { storage[key] }
    func set(_ key: String, _ value: String) { storage[key] = value }
    func delete(_ key: String) { storage[key] = nil }
}

/// Fake HTTP that answers by URL path and records the requests it saw.
private final class FakeHTTP: HTTPClient {
    var responses: [String: (Int, Data)] = [:]   // path -> (status, body)
    private(set) var sent: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        let path = request.url!.path
        guard let (status, data) = responses[path] else { throw CatalogError.httpStatus(599) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func body(_ req: URLRequest) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: String] ?? [:]
    }
}

final class AppAttestSessionTests: XCTestCase {
    private let base = URL(string: "https://apithetin.reyes.ai")!

    func testFreshInstallAttestsAndStoresKeyIdAndToken() async throws {
        let attestor = FakeAttestor()
        let keys = InMemoryKV()
        let http = FakeHTTP()
        let nonce = Base64URL.encode(Data([1, 2, 3, 4]))
        http.responses["/challenge"] = (200, try JSONSerialization.data(withJSONObject: ["nonce": nonce]))
        http.responses["/attest"] = (200, try JSONSerialization.data(withJSONObject: ["sessionToken": "tok-1"]))

        let sp = AppAttestSessionProvider(baseURL: base, attestor: attestor, http: http, keys: keys)
        let token = try await sp.authToken()

        XCTAssertEqual(token, "tok-1")
        // clientDataHash is SHA256 of the DECODED nonce bytes.
        XCTAssertEqual(attestor.attestHashes.first, Data(SHA256.hash(data: Data([1, 2, 3, 4]))))
        // nonce echoed verbatim; keyId re-encoded base64url of "ABC".
        let attestReq = http.sent.first { $0.url!.path == "/attest" }!
        let body = http.body(attestReq)
        XCTAssertEqual(body["nonce"], nonce)
        XCTAssertEqual(body["keyId"], Base64URL.encode(Data("ABC".utf8)))
        XCTAssertEqual(body["attestationObject"], Base64URL.encode(Data("attestation".utf8)))
        XCTAssertNotNil(keys.get("selfhost.appattest.keyId"))
        XCTAssertEqual(keys.get("selfhost.session.token"), "tok-1")
    }

    func testCachedTokenSkipsNetwork() async throws {
        let keys = InMemoryKV(); keys.set("selfhost.session.token", "cached")
        let http = FakeHTTP()
        let sp = AppAttestSessionProvider(baseURL: base, attestor: FakeAttestor(), http: http, keys: keys)
        let token = try await sp.authToken()
        XCTAssertEqual(token, "cached")
        XCTAssertTrue(http.sent.isEmpty)
    }

    func testRefreshWithExistingKeyIdAsserts() async throws {
        let attestor = FakeAttestor()
        let keys = InMemoryKV()
        keys.set("selfhost.appattest.keyId", "QUJD")     // already attested
        keys.set("selfhost.session.token", "old")
        let http = FakeHTTP()
        let nonce = Base64URL.encode(Data([9, 9]))
        http.responses["/challenge"] = (200, try JSONSerialization.data(withJSONObject: ["nonce": nonce]))
        http.responses["/assert"] = (200, try JSONSerialization.data(withJSONObject: ["sessionToken": "tok-2"]))

        let sp = AppAttestSessionProvider(baseURL: base, attestor: attestor, http: http, keys: keys)
        let token = try await sp.refreshedToken()

        XCTAssertEqual(token, "tok-2")
        XCTAssertEqual(attestor.assertHashes.first, Data(SHA256.hash(data: Data([9, 9]))))
        XCTAssertTrue(attestor.attestHashes.isEmpty)     // did NOT re-attest
        XCTAssertEqual(keys.get("selfhost.session.token"), "tok-2")
    }

    func testStaleDeviceFallsBackToAttest() async throws {
        // keyId present but /assert rejects (unknown_device) -> clear key, re-attest.
        let attestor = FakeAttestor()
        let keys = InMemoryKV()
        keys.set("selfhost.appattest.keyId", "QUJD")
        let http = FakeHTTP()
        let nonce = Base64URL.encode(Data([7]))
        http.responses["/challenge"] = (200, try JSONSerialization.data(withJSONObject: ["nonce": nonce]))
        http.responses["/assert"] = (401, Data())
        http.responses["/attest"] = (200, try JSONSerialization.data(withJSONObject: ["sessionToken": "tok-3"]))

        let sp = AppAttestSessionProvider(baseURL: base, attestor: attestor, http: http, keys: keys)
        let token = try await sp.refreshedToken()
        XCTAssertEqual(token, "tok-3")
        XCTAssertFalse(attestor.attestHashes.isEmpty)    // re-attested
    }

    func testUnsupportedDeviceThrows() async {
        let attestor = FakeAttestor(); attestor.isSupported = false
        let sp = AppAttestSessionProvider(baseURL: base, attestor: attestor, http: FakeHTTP(), keys: InMemoryKV())
        do { _ = try await sp.authToken(); XCTFail("expected throw") }
        catch { /* expected */ }
    }
}
