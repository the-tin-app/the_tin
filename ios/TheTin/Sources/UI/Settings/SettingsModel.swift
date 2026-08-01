import Foundation
import Observation

/// Backs the Settings > Storage section: reports the durable image cache's size and clears it.
@MainActor @Observable
final class SettingsModel {
    private(set) var sizeText: String = "…"
    /// Installed catalog version, read from its on-disk state file. (The scanner pack has its own
    /// Settings section, driven live by `ScannerPackModel` — it needs actions, not just a label.)
    private(set) var catalogText: String = "…"
    /// Live connection snapshot for the Connection section (nil until the first probe returns).
    private(set) var connection: ConnectionStatus?
    private(set) var probing = false
    private let cache: ImageCache

    init(cache: ImageCache = .shared) {
        self.cache = cache
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
