import Foundation

/// Wishlist price alerts (spec 2026-07-14): snapshot wanted-card prices after each catalog
/// install, diff against the previous snapshot, post local notifications for meaningful movers.
/// The diff/batching logic is static and IO-free so it's unit-testable; IO arrives in later tasks.
final class PriceAlertsService {

    struct Mover: Equatable {
        let cardId: String
        let oldUsd: Double
        let newUsd: Double
        /// Signed fractional change relative to the old price (−0.18 == dropped 18%).
        var pct: Double { (newUsd - oldUsd) / oldUsd }
    }

    /// Cards whose price moved at least `threshold` (a fraction, e.g. 0.10) since the old
    /// snapshot. Rules: |Δ|/old ≥ threshold AND old ≥ `floorUsd` ($1 floor kills penny-card
    /// noise). Cards with no baseline (hearted since the last snapshot) or no new price (id
    /// vanished from the catalog) are skipped. Sorted by |pct| descending (card-id tie-break)
    /// so digests lead with the biggest move.
    static func movers(old: [String: Double], new: [String: Double],
                       threshold: Double, floorUsd: Double = 1.0) -> [Mover] {
        old.compactMap { id, oldUsd -> Mover? in
            guard oldUsd >= floorUsd, let newUsd = new[id] else { return nil }
            let mover = Mover(cardId: id, oldUsd: oldUsd, newUsd: newUsd)
            return abs(mover.pct) >= threshold ? mover : nil
        }
        .sorted { abs($0.pct) == abs($1.pct) ? $0.cardId < $1.cardId : abs($0.pct) > abs($1.pct) }
    }

    struct Alert: Equatable {
        let title: String
        let body: String
    }

    /// Spec batching: 1–3 movers ⇒ one notification each ("Charizard ex dropped 18% → $210");
    /// >3 ⇒ a single digest naming the top 3 by magnitude with a "…" tail. `names` maps
    /// card id → display name (the id itself is the fallback).
    static func alerts(for movers: [Mover], names: [String: String]) -> [Alert] {
        guard !movers.isEmpty else { return [] }
        func name(_ m: Mover) -> String { names[m.cardId] ?? m.cardId }
        func pct(_ m: Mover) -> String { "\(Int((abs(m.pct) * 100).rounded()))%" }
        if movers.count <= 3 {
            return movers.map { m in
                Alert(title: "\(name(m)) \(m.newUsd < m.oldUsd ? "dropped" : "rose") \(pct(m)) → \(usd(m.newUsd))",
                      body: "Was \(usd(m.oldUsd))")
            }
        }
        let top = movers.prefix(3).map { "\(name($0)) \($0.newUsd < $0.oldUsd ? "↓" : "↑")\(pct($0))" }
        return [Alert(title: "\(movers.count) wishlist cards moved",
                      body: top.joined(separator: ", ") + ", …")]
    }

    /// "$210" for whole dollars, "$3.75" otherwise.
    static func usd(_ value: Double) -> String {
        value == value.rounded() ? "$\(Int(value))" : String(format: "$%.2f", value)
    }

    // MARK: - IO (snapshot + install hook)

    /// Snapshot shape per spec: { catalogVersion, asOf, prices: { cardId: usd } }.
    struct Snapshot: Codable, Equatable {
        var catalogVersion: Int
        var asOf: String?
        var prices: [String: Double]
    }

    /// userInfo["route"] value stamped on every alert; NotificationRouter matches on it.
    static let wishlistRoute = "wishlist"

    private let snapshotURL: URL
    private let wantsURL: URL
    private let notifier: LocalNotifier

    init(snapshotURL: URL = FileManager.default
             .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
             .appendingPathComponent("wishlist-price-snapshot.json"),
         wantsURL: URL = WantsPaths.default().fileURL,
         notifier: LocalNotifier = UserNotificationNotifier()) {
        self.snapshotURL = snapshotURL
        self.wantsURL = wantsURL
        self.notifier = notifier
    }

    private func loadSnapshot() -> Snapshot? {
        (try? Data(contentsOf: snapshotURL))
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
    }

    private func save(_ snapshot: Snapshot) {
        try? FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: snapshotURL, options: .atomic)
        }
    }

    /// Runs after every successful catalog install (AppModel's failover funnel — foreground
    /// start, tier switch, background refresh, BG tasks). Diffs new wanted-card prices against
    /// the previous snapshot, posts alerts if enabled, then overwrites the snapshot. The
    /// snapshot is written even while alerts are OFF; only the notify step is gated. Opens its
    /// own read connection (GRDB DatabaseQueue, WAL) so it needs no live AppModel store.
    func runAfterInstall(version: Int, dbPath: String) async {
        // wants.json is the file LocalWantsRepository maintains. Reuse its format-aware loader
        // (current {id: WantEntry} object, legacy id array) so background runs stay correct
        // without a @MainActor repository.
        let wanted = Array(LocalWantsRepository.load(from: wantsURL).keys)
        guard let store = try? CatalogStore(path: dbPath) else { return }
        defer { try? store.close() }

        let newPrices = ((try? store.prices(cardIds: wanted)) ?? [:])
            .compactMapValues(\.rawUsd)

        if AppConfig.priceAlertsEnabled, let old = loadSnapshot() {
            let movers = Self.movers(old: old.prices, new: newPrices,
                                     threshold: Double(AppConfig.priceAlertSensitivityPct) / 100)
            if !movers.isEmpty {
                let names = ((try? store.cards(ids: movers.map(\.cardId))) ?? [])
                    .reduce(into: [String: String]()) { $0[$1.id] = $1.name }
                for alert in Self.alerts(for: movers, names: names) {
                    await notifier.post(title: alert.title, body: alert.body,
                                        userInfo: ["route": Self.wishlistRoute])
                }
            }
        }
        save(Snapshot(catalogVersion: version,
                      asOf: (try? store.priceAsOf()) ?? nil,
                      prices: newPrices))
    }
}
