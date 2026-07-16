import Foundation
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore

/// Builds a URLRequest for a Firebase Storage REST download that carries the App Check
/// token (required — Storage App Check enforcement is ON) and, when a user is signed in,
/// the Firebase Auth ID token (populates `request.auth` for Storage security rules).
///
/// Guards on `FirebaseApp.app() != nil` first: unlike most Firebase APIs, `AppCheck.appCheck()`
/// and `Auth.auth()` raise an uncaught NSException (not a catchable Swift `Error`, so `try?`
/// cannot stop it) when the default app hasn't been configured. `AppModel(skipFirebase: true)` —
/// used for the hosted unit-test launch (see `TheTin.swift`'s `isTesting` check) — intentionally
/// never configures Firebase while still exercising the real `HTTPCatalogRemote`/
/// `HTTPFingerprintRemote`, so without this guard every test run crashes the test host at launch.
enum StorageAuth {
    static func authorizedRequest(url: URL) async -> URLRequest {
        var req = URLRequest(url: url)
        guard FirebaseApp.app() != nil else { return req }
        if let appCheck = try? await AppCheck.appCheck().token(forcingRefresh: false) {
            req.setValue(appCheck.token, forHTTPHeaderField: "X-Firebase-AppCheck")
        }
        if let user = Auth.auth().currentUser, let idToken = try? await user.getIDToken() {
            req.setValue("Firebase \(idToken)", forHTTPHeaderField: "Authorization")
        }
        return req
    }
}
