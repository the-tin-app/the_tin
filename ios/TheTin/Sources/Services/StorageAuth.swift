import Foundation
import FirebaseAppCheck
import FirebaseCore

/// The App Check token that authorizes the R2 backup origin (`Authorizers.appCheck`).
///
/// Guards on `FirebaseApp.app() != nil` first: unlike most Firebase APIs, `AppCheck.appCheck()`
/// raises an uncaught NSException (not a catchable Swift `Error`, so `try?` cannot stop it) when
/// the default app hasn't been configured. `AppModel(skipFirebase: true)` — the hosted unit-test
/// launch, see `TheTin.swift`'s `isTesting` check — never configures Firebase, so without this
/// guard every test run crashes the test host at launch.
enum StorageAuth {
    static func appCheckToken(forcingRefresh: Bool) async -> String? {
        guard FirebaseApp.app() != nil else { return nil }
        return try? await AppCheck.appCheck().token(forcingRefresh: forcingRefresh).token
    }
}
