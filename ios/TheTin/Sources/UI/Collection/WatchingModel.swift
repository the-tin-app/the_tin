import Foundation
import Observation

/// The four sections of the Watching screen, each read straight from the catalog or from the
/// already-persisted widget snapshot.
///
/// **There is no event log and no diff.** A screen shows STATE — "you're watching for $75 and
/// it's $71" is correct every time you look at it. The edge-triggering the deleted price alerts
/// needed existed only because a *notification* repeats; nothing here repeats.
///
/// ⚠️ Three of the four sections are empty on the **casual** tier, where `price_history` and
/// `price_delta` ship with zero rows — and the simulator is always casual, because App Attest
/// can't run there. Each section hides itself rather than rendering a flat line: an empty
/// history still buckets into something that *looks* like a trend, which is the trap the widget
/// fell into once already (`CollectionView` gates on `cardsWithHistory > 0`, not point count).
@MainActor @Observable final class WatchingModel {

    struct HuntingItem: Identifiable {
        let card: CardRecord
        let entry: WantEntry?
        let setName: String?
        let printedTotal: Int?
        let marketUsd: Double?
        let delta7d: Double?
        var id: String { card.id }
    }

    struct DropItem: Identifiable {
        let card: CardRecord
        let targetUsd: Double?
        let marketUsd: Double?
        let pct7d: Double
        var id: String { card.id }
    }

    struct Trend: Equatable {
        let upWeeks: Int
        let totalWeeks: Int
        /// Change across the whole window, as a fraction.
        let pct: Double
    }

    struct GrailItem: Identifiable {
        let card: CardRecord
        let marketUsd: Double?
        let trend: Trend
        var id: String { card.id }
    }

    private(set) var hunting: [HuntingItem] = []
    private(set) var tin: WidgetSnapshot?
    private(set) var drops: [DropItem] = []
    private(set) var grails: [GrailItem] = []
    private(set) var asOf: String?
    private(set) var loaded = false

    /// The grail trend window, in weekly steps. Fixed at 8 so the sentence ("up 6 of the last 8
    /// weeks") and the percentage describe the same span.
    nonisolated static let trendWeeks = 8
    /// Rows in the drops section. It is a summary, not a second wishlist.
    nonisolated static let maxDrops = 5

    // MARK: - Decisions (pure, tested)

    /// Wishlist cards eligible for the drops section: everything you want that you are NOT
    /// hunting. A hunted card already leads the screen.
    nonisolated static func dropCandidateIds(entries: [String: WantEntry]) -> [String] {
        entries.filter { $0.value.hunt == nil }.keys.sorted()
    }

    /// Biggest drops first, only past Discover's threshold, capped.
    ///
    /// ⚠️ `pct7d` is a **fraction** (−0.12 is a 12% drop), and `DiscoverConstants.dealsMaxPct7d`
    /// is reused rather than a second definition of "a drop" being invented here — two constants
    /// would drift, and one of them being wrong by 100× is exactly how the Deals filter came to
    /// match nothing for months.
    nonisolated static func rankedDrops(pct7dById: [String: Double]) -> [String] {
        pct7dById
            .filter { $0.value < DiscoverConstants.dealsMaxPct7d }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
            .prefix(maxDrops)
            .map(\.key)
    }

    /// "Up N of the last M weeks", plus the change across that same window. `nil` when there
    /// isn't enough history to say anything — which is every card on the casual tier.
    nonisolated static func trend(weeklyUsd: [Double]) -> Trend? {
        let window = Array(weeklyUsd.suffix(trendWeeks + 1))
        guard window.count >= 2, let first = window.first, let last = window.last, first > 0
        else { return nil }
        let up = zip(window, window.dropFirst()).filter { $1 > $0 }.count
        return Trend(upWeeks: up, totalWeeks: window.count - 1, pct: (last - first) / first)
    }

    /// Whether the Tin row shows its dot. `asOf` is the catalog's price date (`yyyy-MM-dd`,
    /// which sorts lexicographically), `lastSeen` the one stored when Watching was last opened.
    /// Deliberately a comparison, not a count: with the event log deleted there is nothing to
    /// count that wouldn't be permanent state and never clear.
    nonisolated static func hasUnseen(asOf: String?, lastSeen: String?) -> Bool {
        guard let asOf else { return false }
        guard let lastSeen else { return true }
        return asOf > lastSeen
    }

    // MARK: - Load

    func load(store: CatalogStore, wants: WantsModel) async {
        let entries = wants.entries
        let huntIds = entries.filter { $0.value.hunt != nil }.map(\.key)
        let dropIds = Self.dropCandidateIds(entries: entries)
        let grailIds = entries.filter { $0.value.priority == .grail }.map(\.key)
        let allIds = Array(Set(huntIds + dropIds + grailIds))

        let cardsById = Dictionary(uniqueKeysWithValues:
            ((try? store.cards(ids: allIds)) ?? []).map { ($0.id, $0) })
        // compactMapValues: a null raw_usd (EUR- or graded-only) is unpriced, not $0.
        let prices = ((try? store.prices(cardIds: allIds)) ?? [:]).compactMapValues(\.rawUsd)
        let deltas = (try? store.deltas(cardIds: allIds)) ?? [:]
        let setsById = Dictionary(uniqueKeysWithValues:
            ((try? store.sets()) ?? []).map { ($0.id, $0) })

        // `kind == .raw, key == ""` is the ungraded market row — the same one Browse's
        // biggest-drop sort joins on.
        func pct7d(_ id: String) -> Double? {
            deltas[id]?.first { $0.kind == .raw && $0.key.isEmpty }?.pct7d
        }

        var printedTotals: [String: Int] = [:]
        for setId in Set(huntIds.compactMap { cardsById[$0]?.setId }) {
            printedTotals[setId] = try? store.printedTotal(setId: setId)
        }

        hunting = WishlistGrid
            .huntSorted(cards: huntIds.compactMap { cardsById[$0] }, entries: entries,
                        prices: prices)
            .map { card in
                HuntingItem(card: card, entry: entries[card.id],
                            setName: setsById[card.setId]?.name,
                            printedTotal: printedTotals[card.setId],
                            marketUsd: prices[card.id], delta7d: pct7d(card.id))
            }

        let dropPcts = Dictionary(uniqueKeysWithValues:
            dropIds.compactMap { id in pct7d(id).map { (id, $0) } })
        drops = Self.rankedDrops(pct7dById: dropPcts).compactMap { id in
            guard let card = cardsById[id], let pct = dropPcts[id] else { return nil }
            return DropItem(card: card, targetUsd: entries[id]?.targetUsd,
                            marketUsd: prices[id], pct7d: pct)
        }

        let histories = (try? store.priceHistory(cardIds: grailIds)) ?? [:]
        grails = grailIds.compactMap { id -> GrailItem? in
            guard let card = cardsById[id],
                  let t = Self.trend(weeklyUsd: (histories[id] ?? []).map(\.value))
            else { return nil }
            return GrailItem(card: card, marketUsd: prices[id], trend: t)
        }
        .sorted { abs($0.trend.pct) > abs($1.trend.pct) }

        // The tin's weekly movement is ALREADY computed and persisted for the widget. Do not
        // call `PortfolioHistory.series` here: it is one SQL query per priced card, which is
        // why `CollectionView` moved it off the main actor.
        tin = WidgetShared.loadSnapshot()
        asOf = (try? store.priceAsOf()) ?? nil
        loaded = true
    }
}
