import Foundation
import DeviceCheck
import Security

/// Apple App Attest, behind a protocol so `AppAttestSessionProvider` is testable with a fake.
/// The real impl is a thin pass-through to `DCAppAttestService` — the untestable Apple boundary.
protocol Attestor {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

struct DeviceCheckAttestor: Attestor {
    private let service = DCAppAttestService.shared
    var isSupported: Bool { service.isSupported }
    func generateKey() async throws -> String { try await service.generateKey() }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await service.attestKey(keyId, clientDataHash: clientDataHash)
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}

/// Minimal string key/value persistence, behind a protocol so session tests use an in-memory fake.
protocol KeyValueStore {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func delete(_ key: String)
}

/// Device-local Keychain (generic password). NOT iCloud-synced: App Attest keys are
/// hardware-bound and cannot migrate across devices/reinstall, so syncing the key id (or the
/// cheap-to-remint session token) would be a lie — a fresh install simply re-attests.
struct KeychainStore: KeyValueStore {
    var service: String = "ai.reyes.thetin.selfhost"

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        var attrs = query(key)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}
