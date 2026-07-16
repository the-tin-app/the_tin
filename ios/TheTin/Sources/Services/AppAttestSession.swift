import Foundation
import CryptoKit

/// Supplies a self-host Bearer session token, minting/renewing it via App Attest.
protocol SessionProvider {
    /// Cached token if present, else freshly minted.
    func authToken() async throws -> String
    /// Force a brand-new token (used after the server rejects the cached one with 401).
    func refreshedToken() async throws -> String
}

/// App Attest session lifecycle: `GET /challenge` → attest (first run) or assert (renewal) →
/// `{ sessionToken }`. Key id + token persist in `keys` (device-local Keychain in production).
final class AppAttestSessionProvider: SessionProvider {
    private let baseURL: URL
    private let attestor: Attestor
    private let http: HTTPClient
    private let keys: KeyValueStore
    private var cachedToken: String?

    private let keyIdKey = "selfhost.appattest.keyId"
    private let tokenKey = "selfhost.session.token"

    init(baseURL: URL, attestor: Attestor, http: HTTPClient, keys: KeyValueStore) {
        self.baseURL = baseURL
        self.attestor = attestor
        self.http = http
        self.keys = keys
        self.cachedToken = keys.get(tokenKey)
    }

    func authToken() async throws -> String {
        if let t = cachedToken { return t }
        return try await mint()
    }

    func refreshedToken() async throws -> String {
        cachedToken = nil
        keys.delete(tokenKey)
        return try await mint()
    }

    private func mint() async throws -> String {
        guard attestor.isSupported else { throw CatalogError.badResponse }
        let token: String
        if keys.get(keyIdKey) != nil {
            do { token = try await assert() }
            catch { keys.delete(keyIdKey); token = try await attest() }   // stale device → re-attest
        } else {
            token = try await attest()
        }
        cachedToken = token
        keys.set(tokenKey, token)
        return token
    }

    private func attest() async throws -> String {
        let nonce = try await challenge()
        let hash = clientDataHash(nonce)
        let appleKeyId = try await attestor.generateKey()
        keys.set(keyIdKey, appleKeyId)
        let attestation = try await attestor.attestKey(appleKeyId, clientDataHash: hash)
        return try await postForToken(path: "attest", body: [
            "keyId": wireKeyId(appleKeyId),
            "nonce": nonce,
            "attestationObject": Base64URL.encode(attestation),
        ])
    }

    private func assert() async throws -> String {
        let appleKeyId = keys.get(keyIdKey)!
        let nonce = try await challenge()
        let hash = clientDataHash(nonce)
        let assertion = try await attestor.generateAssertion(appleKeyId, clientDataHash: hash)
        return try await postForToken(path: "assert", body: [
            "keyId": wireKeyId(appleKeyId),
            "nonce": nonce,
            "assertionObject": Base64URL.encode(assertion),
        ])
    }

    private func challenge() async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("challenge"))
        req.timeoutInterval = AppConfig.selfHostTimeout
        let (data, http) = try await self.http.send(req)
        guard http.statusCode == 200 else { throw CatalogError.httpStatus(http.statusCode) }
        struct R: Decodable { let nonce: String }
        return try JSONDecoder().decode(R.self, from: data).nonce
    }

    private func postForToken(path: String, body: [String: String]) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = AppConfig.selfHostTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await self.http.send(req)
        guard http.statusCode == 200 else { throw CatalogError.httpStatus(http.statusCode) }
        struct R: Decodable { let sessionToken: String }
        return try JSONDecoder().decode(R.self, from: data).sessionToken
    }

    /// Server computes `SHA256(decoded nonce bytes)`; mirror that exactly.
    private func clientDataHash(_ nonce: String) -> Data {
        let bytes = Base64URL.decode(nonce) ?? Data(nonce.utf8)
        return Data(SHA256.hash(data: bytes))
    }

    /// Apple returns standard-base64 key ids; the server decodes base64url. Re-encode the raw bytes.
    private func wireKeyId(_ appleKeyId: String) -> String {
        Base64URL.encode(Data(base64Encoded: appleKeyId) ?? Data())
    }
}
