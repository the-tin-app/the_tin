import Foundation
import Observation

/// Backs the Settings > Storage section: reports the durable image cache's size and clears it.
@MainActor @Observable
final class SettingsModel {
    private(set) var sizeText: String = "…"
    /// Installed version of each Firebase Storage artifact, read from its on-disk state file.
    private(set) var catalogText: String = "…"
    private(set) var fingerprintText: String = "…"
    /// Live connection snapshot for the Connection section (nil until the first probe returns).
    private(set) var connection: ConnectionStatus?
    private(set) var probing = false
    private let cache: ImageCache
    private let notifier: LocalNotifier

    // Wishlist price alerts (spec 2026-07-14). Mirrors AppConfig so the UI updates reactively.
    private(set) var alertsEnabled = AppConfig.priceAlertsEnabled
    private(set) var alertSensitivityPct = AppConfig.priceAlertSensitivityPct
    /// True when iOS notification permission is denied — drives the "enable in iOS Settings" hint.
    private(set) var alertsDenied = false

    init(cache: ImageCache = .shared, notifier: LocalNotifier = UserNotificationNotifier()) {
        self.cache = cache
        self.notifier = notifier
    }

    /// Probe both backends (Settings appear + manual Refresh). Never throws.
    func probeConnections(app: AppModel) async {
        probing = true
        connection = await app.probeConnections()
        probing = false
    }

    func refresh() async {
        let bytes = await cache.totalBytes()
        let count = await cache.fileCount()
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        sizeText = "\(size) · \(count) image\(count == 1 ? "" : "s")"

        catalogText = Self.artifactSummary(url: CatalogPaths.default().stateURL) {
            (try? JSONDecoder().decode(CatalogState.self, from: $0)).map { "v\($0.version)" }
        }
        fingerprintText = Self.artifactSummary(url: FingerprintPaths.default().stateURL) {
            (try? JSONDecoder().decode(FingerprintState.self, from: $0)).map { "v\($0.version)" }
        }
        if alertsEnabled { alertsDenied = await notifier.isAuthorizationDenied() }
    }

    /// Toggle flow per spec: turning ON requests notification permission first; a denial leaves
    /// the toggle off and shows the Settings hint. Turning OFF never touches permissions (the
    /// snapshot keeps updating regardless — see PriceAlertsService.runAfterInstall).
    func setAlertsEnabled(_ on: Bool) async {
        if on {
            let granted = await notifier.requestAuthorization()
            alertsDenied = !granted
            AppConfig.priceAlertsEnabled = granted
            alertsEnabled = granted
        } else {
            AppConfig.priceAlertsEnabled = false
            alertsEnabled = false
        }
    }

    func setAlertSensitivity(_ pct: Int) {
        AppConfig.priceAlertSensitivityPct = pct
        alertSensitivityPct = pct
    }

    /// "v7 · Jul 11, 2026" from a state file's decoded version + its filesystem mod date
    /// (the install time — no download date is persisted, so mod date is the lazy stand-in).
    private static func artifactSummary(url: URL, version: (Data) -> String?) -> String {
        guard let data = try? Data(contentsOf: url), let v = version(data) else { return "Not downloaded" }
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        guard let date else { return v }
        return "\(v) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    func clear() async {
        await cache.clear()
        await refresh()
    }
}
