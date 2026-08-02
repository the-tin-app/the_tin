import Foundation
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore

/// The App Check token that authorizes the R2 backup origin lives here (`Authorizers.appCheck`).
/// `authorizedRequest(url:)` is a leftover from the old bucket-REST fallback remote that Task 7
/// deleted — nothing in the app calls it any more. Kept only because `CatalogRemoteTests` still
/// pins its "Firebase not configured" guard behavior directly.
///
/// Guards on `FirebaseApp.app() != nil` first: unlike most Firebase APIs, `AppCheck.appCheck()`
/// and `Auth.auth()` raise an uncaught NSException (not a catchable Swift `Error`, so `try?`
/// cannot stop it) when the default app hasn't been configured. `AppModel(skipFirebase: true)` —
/// the hosted unit-test launch, see `TheTin.swift`'s `isTesting` check — never configures
/// Firebase, so without this guard every test run crashes the test host at launch.
enum StorageAuth {
    static func appCheckToken(forcingRefresh: Bool) async -> String? {
        guard FirebaseApp.app() != nil else { return nil }
        return try? await AppCheck.appCheck().token(forcingRefresh: forcingRefresh).token
    }

    /// Builds a URLRequest for a Firebase Storage REST download that carries the App Check
    /// token (required — Storage App Check enforcement is ON) and, when a user is signed in,
    /// the Firebase Auth ID token (populates `request.auth` for Storage security rules).
    static func authorizedRequest(url: URL) async -> URLRequest {
        var req = URLRequest(url: url)
        guard FirebaseApp.app() != nil else { return req }
        if let token = await appCheckToken(forcingRefresh: false) {
            req.setValue(token, forHTTPHeaderField: "X-Firebase-AppCheck")
        }
        if let user = Auth.auth().currentUser, let idToken = try? await user.getIDToken() {
            req.setValue("Firebase \(idToken)", forHTTPHeaderField: "Authorization")
        }
        return req
    }
}
