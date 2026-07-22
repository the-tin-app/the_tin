import SwiftUI

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
            // foreground instead of waiting for the next cold launch.
            if scenePhase == .active { Task { await model.refreshIfStale() } }
        }
    }
}
