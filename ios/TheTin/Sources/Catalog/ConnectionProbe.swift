import Foundation

/// A point-in-time snapshot of both catalog backends, for the Settings > Connection section.
/// Deliberately probed on demand (Settings appear + manual refresh), never polled.
struct ConnectionStatus: Equatable {
    var selfHostConfigured = false
    /// `GET /health` (public, no App Attest) succeeded — the box is up.
    var selfHostAlive = false
    var selfHostLatencyMs: Int?
    /// The authed manifest round-tripped — App Attest is working, not just the box being alive.
    var selfHostAuthOK = false
    var selfHostVersion: Int?
    /// Download size per tier key ("casual"/"average"/"expert"), from the NAS manifest.
    var tierSizes: [String: Int] = [:]
    var firebaseReachable = false
    var firebaseVersion: Int?
}

extension AppModel {
    /// Probe both backends. Splits liveness (`/health`) from auth (`fetchTierCatalog`) because a
    /// live box with broken App Attest is this app's most common failure mode. Never throws.
    func probeConnections() async -> ConnectionStatus {
        var s = ConnectionStatus()

        if let base = AppConfig.selfHostBaseURL {
            s.selfHostConfigured = true

            var req = URLRequest(url: base.appendingPathComponent("health"))
            req.timeoutInterval = AppConfig.selfHostTimeout
            let t0 = Date()
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                s.selfHostAlive = true
                s.selfHostLatencyMs = Int(Date().timeIntervalSince(t0) * 1000)
            }

            if let nas = Self.selfHostedRemote(), let info = try? await nas.fetchTierCatalog() {
                s.selfHostAuthOK = true
                s.selfHostVersion = info.version
                s.tierSizes = info.sizes
            }
        }

        if let m = try? await HTTPCatalogRemote(baseURL: AppConfig.catalogBaseURL).fetchManifest() {
            s.firebaseReachable = true
            s.firebaseVersion = m.version
        }

        return s
    }
}
