import Foundation
import FirebaseAppCheck
import FirebaseCore
import FirebaseAuth

enum FirebaseMode: Equatable {
    case production
    case emulator(host: String)

    static func detect(hasPlist: Bool, isDebug: Bool) -> FirebaseMode? {
        if hasPlist { return .production }
        return isDebug ? .emulator(host: "127.0.0.1") : nil
    }
}

/// App Check provider factory for release builds. The Firebase SDK does not ship a
/// ready-made factory for `AppAttestProvider` (unlike `DeviceCheckProviderFactory` /
/// `AppCheckDebugProviderFactory`), so we implement the one-line adapter ourselves.
final class AppAttestProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app)
    }
}

enum FirebaseBootstrap {
    private(set) static var mode: FirebaseMode?

    /// Idempotent. Returns nil in a release build with no GoogleService-Info.plist
    /// (caller shows an error state — never a silent crash).
    @discardableResult
    static func configure() -> FirebaseMode? {
        if FirebaseApp.app() != nil { return mode }

        let hasPlist = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        guard let detected = FirebaseMode.detect(hasPlist: hasPlist, isDebug: isDebug) else { return nil }

        // App Check provider factory MUST be set before FirebaseApp.configure().
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
        #endif

        switch detected {
        case .production:
            FirebaseApp.configure()
        case .emulator(let host):
            // Stub options: the emulator suite (--project demo-hobby-tcg) validates nothing.
            let options = FirebaseOptions(googleAppID: "1:123456789000:ios:abcdef0123456789",
                                          gcmSenderID: "123456789000")
            options.projectID = "demo-hobby-tcg"
            options.apiKey = "fake-api-key-for-emulator"
            FirebaseApp.configure(options: options)
            Auth.auth().useEmulator(withHost: host, port: 9099)
        }

        // Firestore is no longer used by the app (collection + wishlist are on-device; prices
        // ship in the downloaded catalog). Only Auth (anon token) + App Check gate the Storage
        // downloads. See funding-model-v2 migration.

        mode = detected
        return detected
    }
}
