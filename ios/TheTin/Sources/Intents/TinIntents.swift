import AppIntents
import Foundation

/// Bridges an App Intent to the running UI.
///
/// Intents perform in the app's process but have no handle on `AppModel`, so they park a request
/// here and `TheTin` forwards it — the same shape as `NotificationRouter`, which does this for
/// price-alert taps. A request that arrives before the scene installs its handler (cold launch
/// straight from Siri or the Action button) is held, not dropped.
@MainActor
final class IntentRouter {
    static let shared = IntentRouter()

    private var handler: ((AppModel.IntentRoute) -> Void)?
    private var pending: AppModel.IntentRoute?

    func route(_ route: AppModel.IntentRoute) {
        if let handler { handler(route) } else { pending = route }
    }

    func install(_ handler: @escaping (AppModel.IntentRoute) -> Void) {
        self.handler = handler
        if let pending {
            self.pending = nil
            handler(pending)
        }
    }
}

/// "Hey Siri, scan a card with The Tin" — the one thing worth putting on the Action button,
/// because in a shop you have one free hand.
struct ScanCardIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan a Card"
    static var description = IntentDescription("Open the camera scanner to identify a card.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.route(.scan)
        return .result()
    }
}

struct SearchCardsIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Cards"
    static var description = IntentDescription("Search the card catalog. Works offline.")
    static var openAppWhenRun = true

    @Parameter(title: "Search", requestValueDialog: "What are you looking for?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search cards for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.route(.search(query))
        return .result()
    }
}

/// Answers without launching the app: it reads the same snapshot file the home-screen widget
/// does, so Siri never opens SQLite — and can never disagree with the widget.
struct TinValueIntent: AppIntent {
    static var title: LocalizedStringResource = "Tin Value"
    static var description = IntentDescription("How much your collection is worth.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        guard let snapshot = WidgetShared.loadSnapshot() else {
            // Never answer "$0" — an app that has never run and an empty collection are not the
            // same thing, and only one of them is the user's fault.
            return .result(value: 0,
                           dialog: "Open The Tin once and it'll work out what your collection is worth.")
        }
        let amount = snapshot.totalValue.formatted(WidgetShared.tinCurrency(snapshot.totalValue))
        let cards = "\(snapshot.cardCount) \(snapshot.cardCount == 1 ? "card" : "cards")"
        return .result(value: snapshot.totalValue,
                       dialog: "Your tin is worth \(amount), across \(cards).")
    }
}

/// Registers the three intents with Siri, Shortcuts and Spotlight's shortcut row. Every phrase
/// must contain `\(.applicationName)` — App Intents silently drops the ones that don't.
struct TheTinShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ScanCardIntent(),
                    phrases: ["Scan a card with \(.applicationName)",
                              "Scan a card in \(.applicationName)",
                              "Open the \(.applicationName) scanner"],
                    shortTitle: "Scan a Card",
                    systemImageName: "camera.viewfinder")
        AppShortcut(intent: SearchCardsIntent(),
                    phrases: ["Search cards in \(.applicationName)",
                              "Look up a card in \(.applicationName)",
                              "Search \(.applicationName)"],
                    shortTitle: "Search Cards",
                    systemImageName: "magnifyingglass")
        AppShortcut(intent: TinValueIntent(),
                    phrases: ["What's my \(.applicationName) worth",
                              "How much is my \(.applicationName) worth",
                              "\(.applicationName) value"],
                    shortTitle: "Tin Value",
                    systemImageName: "chart.line.uptrend.xyaxis")
    }
}
