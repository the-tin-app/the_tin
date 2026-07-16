import Foundation

/// Endless stream of the highest-priced cards, paged straight off the price-sorted index.
struct ChaseStream: CardStream {
    let store: CatalogStore
    var pageSize: Int = 20

    func page(_ index: Int) -> [CardRecord] {
        (try? store.topPricedCards(offset: index * pageSize, limit: pageSize)) ?? []
    }
}
