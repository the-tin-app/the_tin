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

    /// A wishlist card that has just come down to the price you said you'd pay for it.
    struct Crossing: Equatable {
        let cardId: String
        let target: Double
        let newUsd: Double
    }

    /// Cards that crossed their target price since the last snapshot.
    ///
    /// **Edge-triggered.** It fires on the crossing, not on the state: the old price must have
    /// been ABOVE the target and the new one at or below it. Reporting "is below target" instead
    /// would re-notify every single night for as long as the card stayed cheap, which is how a
    /// useful alert becomes one you swipe away without reading.
    ///
    /// A card with no previous price has no crossing — it might have been under target for a
    /// year before you added it, and announcing that as news would be a lie. Same `floorUsd` as
    /// `movers`, for the same reason: sub-$1 targets are noise.
    ///
    /// `changedBasis` names cards whose `raw_printing` moved between snapshots. Their two prices
    /// describe different printings, so any "crossing" between them is arithmetic on a basis
    /// flip rather than a market move — the exact defect PRs #83/#84 fixed in the pipeline, and
    /// the one thing that would make this feature cry wolf on its very first outing.
    static func targetCrossings(old: [String: Double], new: [String: Double],
                                targets: [String: Double],
                                changedBasis: Set<String> = [],
                                floorUsd: Double = 1.0) -> [Crossing] {
        targets.compactMap { id, target -> Crossing? in
            guard target >= floorUsd,
                  !changedBasis.contains(id),
                  let oldUsd = old[id], let newUsd = new[id],
                  oldUsd > target, newUsd <= target else { return nil }
            return Crossing(cardId: id, target: target, newUsd: newUsd)
        }
        // Cheapest-relative-to-target first: the best deal leads the digest.
        .sorted { ($0.newUsd / $0.target, $0.cardId) < ($1.newUsd / $1.target, $1.cardId) }
    }

    /// Target hits get their own notifications, ahead of the percentage movers: you asked for
    /// this specific card at this specific price, where a mover is something the market did at
    /// you. Batched on the same rule as `alerts(for:names:)`.
    static func targetAlerts(for crossings: [Crossing], names: [String: String]) -> [Alert] {
        guard !crossings.isEmpty else { return [] }
        func name(_ c: Crossing) -> String { names[c.cardId] ?? c.cardId }
        if crossings.count <= 3 {
            return crossings.map { c in
                Alert(title: "\(name(c)) hit your target — \(usd(c.newUsd))",
                      body: "You were watching for \(usd(c.target)).")
            }
        }
        let top = crossings.prefix(3).map { "\(name($0)) \(usd($0.newUsd))" }
        return [Alert(title: "\(crossings.count) wishlist cards hit your target",
                      body: top.joined(separator: ", ") + ", …")]
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

    /// Snapshot shape per spec: { catalogVersion, asOf, prices: { cardId: usd } }, plus the
    /// printing each price was quoting.
    ///
    /// `printings` is a true `Optional`, NOT a property with a default: a synthesized `Decodable`
    /// ignores defaults and demands the key, so `var printings: [String: String] = [:]` made
    /// every pre-existing snapshot fail to decode. That's silent and nasty — `loadSnapshot()`
    /// returns nil, the baseline is thrown away, and nobody gets an alert the first night after
    /// updating. Same optional-means-"written before this existed" convention as
    /// `CollectionEntry.forTrade` and `BackupSnapshot.setGoals`, and for the same reason.
    /// nil reads as "no basis recorded", which the guard treats as unknown rather than changed.
    struct Snapshot: Codable, Equatable {
        var catalogVersion: Int
        var asOf: String?
        var prices: [String: Double]
        var printings: [String: String]?
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
        // The whole entries map, not just its keys: `targetUsd` lives on the entry, and reading
        // only the ids is why a target price could never make this app say anything.
        let wants = LocalWantsRepository.load(from: wantsURL)
        let wanted = Array(wants.keys)
        guard let store = try? CatalogStore(path: dbPath) else { return }
        defer { try? store.close() }

        let records = (try? store.prices(cardIds: wanted)) ?? [:]
        let newPrices = records.compactMapValues(\.rawUsd)
        let newPrintings = records.compactMapValues(\.rawPrinting)

        if AppConfig.priceAlertsEnabled, let old = loadSnapshot() {
            // A card whose raw_usd changed WHICH printing it quotes has two prices that aren't
            // comparable; drop it from both kinds of alert rather than report the spread between
            // two printings as a move. Unknown-on-either-side is not a change (`IS`, not `=`).
            let changedBasis = Set(newPrintings.compactMap { id, printing -> String? in
                guard let was = old.printings?[id] else { return nil }
                return was == printing ? nil : id
            })
            let targets = wants.compactMapValues(\.targetUsd)
            let crossings = Self.targetCrossings(old: old.prices, new: newPrices,
                                                 targets: targets, changedBasis: changedBasis)
            let movers = Self.movers(old: old.prices, new: newPrices,
                                     threshold: Double(AppConfig.priceAlertSensitivityPct) / 100)
                .filter { !changedBasis.contains($0.cardId) }
            // A card that hit its target is not also a generic mover — one card, one alert, and
            // the target is the more specific thing to say about it.
            let crossed = Set(crossings.map(\.cardId))
            let ids = crossings.map(\.cardId) + movers.map(\.cardId)
            let names = ((try? store.cards(ids: ids)) ?? [])
                .reduce(into: [String: String]()) { $0[$1.id] = $1.name }
            let alerts = Self.targetAlerts(for: crossings, names: names)
                + Self.alerts(for: movers.filter { !crossed.contains($0.cardId) }, names: names)
            for alert in alerts {
                await notifier.post(title: alert.title, body: alert.body,
                                    userInfo: ["route": Self.wishlistRoute])
            }
        }
        save(Snapshot(catalogVersion: version,
                      asOf: (try? store.priceAsOf()) ?? nil,
                      prices: newPrices,
                      printings: newPrintings))
    }
}
