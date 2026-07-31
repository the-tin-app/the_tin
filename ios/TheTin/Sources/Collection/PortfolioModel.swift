import Foundation
import Observation

/// Builds (off-main) and caches the portfolio value series for the whole tin and each divider.
/// Cache is keyed on the entries array; a catalog-version change swaps the CatalogStore and
/// rebuilds the models around it, so entries-equality alone is a sufficient key in practice.
@MainActor @Observable
final class PortfolioModel {
    private let store: CatalogStore
    private(set) var series: PortfolioSeries?
    /// groupId → that divider's series ("" = ungrouped), for the per-divider breakdown.
    private(set) var groupSeries: [String: PortfolioSeries] = [:]
    private var cachedEntries: [CollectionEntry]?
    /// Bumped on every `refresh` entry; guards against an older overlapping refresh's detached
    /// task clobbering a newer one's result if they complete out of order.
    private var generation = 0

    init(store: CatalogStore) { self.store = store }

    func refresh(entries: [CollectionEntry], prices: [String: PriceRecord],
                 variantsByCard: [String: [VariantPrice]],
                 conditionsByCard: [String: [ConditionPrice]],
                 matrixByCard: [String: [MatrixPrice]] = [:],
                 gradedByPrintingByCard: [String: [GradedPrintingPrice]] = [:]) async {
        generation += 1
        guard entries != cachedEntries else { return }
        let gen = generation
        let store = self.store   // @unchecked Sendable — safe to hand to a detached task
        let (whole, perGroup) = await Task.detached(priority: .userInitiated) {
            () -> (PortfolioSeries, [String: PortfolioSeries]) in
            let ids = Array(Set(entries.map(\.cardId)))
            let histories = (try? store.priceHistory(cardIds: ids)) ?? [:]
            func build(_ list: [CollectionEntry]) -> PortfolioSeries {
                PortfolioHistory.series(entries: list, histories: histories, prices: prices,
                                        variantsByCard: variantsByCard,
                                        conditionsByCard: conditionsByCard,
                                        matrixByCard: matrixByCard,
                                        gradedByPrintingByCard: gradedByPrintingByCard)
            }
            var perGroup: [String: PortfolioSeries] = [:]
            for gid in Set(entries.map(\.groupId)) {
                perGroup[gid] = build(entries.filter { $0.groupId == gid })
            }
            return (build(entries), perGroup)
        }.value
        guard gen == self.generation else { return }
        series = whole
        groupSeries = perGroup
        cachedEntries = entries
    }
}
