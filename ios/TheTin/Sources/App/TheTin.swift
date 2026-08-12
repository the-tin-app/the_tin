import SwiftUI
import TipKit

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
        // One flag, defined next to the scheduler that has to agree with it — a second local copy
        // here is what let `register` skip under test while the submit below did not.
        let isTesting = BackgroundRefresh.isTesting
        // Tips are suppressed under XCTest: a popover over the control a UI test is driving is a
        // flake, and the display-rule store is per-container state a test host shouldn't inherit.
        if !isTesting { try? Tips.configure() }
        let model = AppModel.makeDefault(skipFirebase: isTesting)
        _model = State(initialValue: model)
        // BGTaskScheduler requires all launch handlers registered before the app finishes
        // launching; skip under XCTest (no Info.plist-gated task ids in the test host run).
        if !isTesting { BackgroundRefresh.register(model: model) }
        // Siri / Shortcuts / the Action button. Installed here rather than in a view so a cold
        // launch straight from an intent has somewhere to deliver before any body runs.
        MainActor.assumeIsolated { IntentRouter.shared.install { model.openIntentRoute($0) } }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(appearance.colorScheme)
                .task { await model.start() }
                // Custom schemes and opened FILES (the CSV import) arrive here.
                .onOpenURL { model.handleDeepLink($0) }
                // ⚠️ UNIVERSAL LINKS DO NOT RELIABLY ARRIVE VIA `onOpenURL`, and on a cold launch
                // they do not arrive there at all. They are delivered as an `NSUserActivity` of
                // type `NSUserActivityTypeBrowsingWeb`, and without this handler the app launches
                // and sits there.
                //
                // Measured on device 2026-08-10, not inferred: force-quit, scan a printed label
                // with the system Camera, tap the banner — the app launches and the breadcrumb
                // trail shows `consumeCardRoute: token=0 pendingId=nil`. No `handleDeepLink`, no
                // `openCard`. iOS handed us nothing.
                //
                // This is PRE-EXISTING and has nothing to do with labels: every `/c/<id>` share
                // link since v1.0 has behaved the same way. It stayed hidden because
                // `DeepLinkRoutingTests` only ever tested `handleDeepLink`, never how a URL
                // reaches it, and because the `/l` trade-link bug was diagnosed with the app
                // already running.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    model.handleDeepLink(url)
                }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background { BackgroundRefresh.scheduleRefresh() }
            // Daily catalogs usually publish while the app sits suspended — catch up on
            // foreground instead of waiting for the next cold launch.
            if scenePhase == .active { Task { await model.refreshIfStale() } }
        }
    }
}
