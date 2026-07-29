import SwiftUI
import UIKit

/// User-selected appearance: follow the system, or force light/dark. Persisted raw in
/// UserDefaults; `colorScheme` nil means "follow system".
enum Appearance: String, CaseIterable {
    case system, light, dark

    static let storageKey = "appearance"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

@main
struct TheTin: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system

    init() {
        let isTesting = NSClassFromString("XCTestCase") != nil
        let model = AppModel.makeDefault(skipFirebase: isTesting)
        _model = State(initialValue: model)
        // BGTaskScheduler requires all launch handlers registered before the app finishes
        // launching; skip under XCTest (no Info.plist-gated task ids in the test host run).
        if !isTesting { BackgroundRefresh.register(model: model) }
        NotificationRouter.shared.install()
        NotificationRouter.shared.onWishlistTap = { model.openWishlist() }
        // Siri / Shortcuts / the Action button. Installed here rather than in a view so a cold
        // launch straight from an intent has somewhere to deliver before any body runs.
        MainActor.assumeIsolated { IntentRouter.shared.install { model.openIntentRoute($0) } }
        // The APNs token CKSyncEngine's silent zone pushes are delivered to. Prompts nobody —
        // silent pushes need no user authorisation, only a token — and there is no callback to
        // handle: the engine owns its own subscription and listens for the push itself, so this
        // one line is the whole client side of push.
        //
        // Unconditional rather than gated on the sync toggle: a token is cheap and idempotent,
        // whereas gating means re-registering when the toggle flips and a window where sync is on
        // with no token. Without the CloudKit entitlement it is inert — nothing subscribes.
        if !isTesting { MainActor.assumeIsolated { UIApplication.shared.registerForRemoteNotifications() } }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(appearance.colorScheme)
                .task { await model.start() }
                .onOpenURL { model.handleDeepLink($0) }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background { BackgroundRefresh.scheduleRefresh() }
            // Daily catalogs usually publish while the app sits suspended — catch up on
            // foreground instead of waiting for the next cold launch. The other device's edits
            // arrive the same way and for the same reason: without push, `CKSyncEngine` fetches
            // only for push and for local pending changes, so a device that merely sat there
            // never hears that something was deleted. Both are cheap no-ops when nothing is new.
            if scenePhase == .active {
                Task { await model.refreshIfStale() }
                Task { await model.sync?.refresh() }
            }
        }
    }
}
