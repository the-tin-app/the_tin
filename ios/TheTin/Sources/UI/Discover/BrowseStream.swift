import Foundation

/// Endless filtered browse. Pure `page(_:)` over `CatalogStore.browse`, so it runs off-main via
/// `StreamPager` exactly like the curated streams. Deterministic: SQL `LIMIT/OFFSET` + stable order.
struct BrowseStream: CardStream {
    let store: CatalogStore
    let criteria: BrowseCriteria
    let ownedIds: [String]
    var pageSize: Int = 15

    func page(_ index: Int) -> [CardRecord] {
        (try? store.browse(criteria: criteria, ownedIds: ownedIds,
                           offset: index * pageSize, limit: pageSize)) ?? []
    }
}
