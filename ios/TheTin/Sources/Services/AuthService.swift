import Foundation
import FirebaseAuth
import os

enum AuthService {
    private static let logger = Logger(subsystem: "ai.reyes.thetin", category: "AuthService")

    /// Anonymous-only identity (spec §4, zero PII). The credential is kept in the
    /// Keychain with iCloud sync so the uid survives reinstall and device moves.
    static func ensureSignedIn() async throws -> String {
        let auth = Auth.auth()
        auth.shareAuthStateAcrossDevices = true
        if let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
           !prefix.isEmpty {
            // Access-group storage is what makes shareAuthStateAcrossDevices effective.
            do {
                try auth.useUserAccessGroup(prefix + "ai.reyes.thetin")
            } catch {
                // Non-fatal: anonymous auth still works locally, but cross-device/
                // reinstall persistence is silently degraded without this. Surface
                // it loudly so a misconfigured entitlement doesn't go unnoticed.
                logger.error("Failed to set Keychain access group; cross-device auth persistence is degraded: \(String(describing: error), privacy: .public)")
                #if DEBUG
                assertionFailure("useUserAccessGroup failed: \(error)")
                #endif
            }
        }
        if let user = auth.currentUser { return user.uid }
        let result = try await auth.signInAnonymously()
        return result.user.uid
    }
}
