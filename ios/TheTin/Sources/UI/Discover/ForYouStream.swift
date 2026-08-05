import Foundation

/// The For You home strip and deck: a round-robin across the shelves, so the first screen shows one
/// card per reason rather than a run from whichever reason happened to score highest.
///
/// ⚠️ **This used to build a pool in memory and rank it, and the pool was doing almost nothing.**
/// Measured against the real served catalog: page 0 pulled 3,960 cards and page 5 pulled 9,615, of
/// which 39 and 182 survived `perGroupCap: 3` — so ~98% of the scoring was discarded by a rule that
/// was not the score, and the cap was silently doing the ranking. A shelf IS that cap, named and
/// explainable.
///
/// `varietyPicks`, `bucketDepth`, `experimentSlots`, `interleave` and `popularMix` are all gone.
/// Variety is the `explore` shelf, and it passes the same `ShelfBuilder` seam as everything else —
/// which is the fix for a $4,500 card sitting at slot 4 of a deck banded at $5–$34.
struct ForYouStream: CardStream {
    let store: CatalogStore
    let shelves: [Shelf]
    var pageSize: Int = 12

    /// Card ids in round-robin order across shelves, deduped.
    ///
    /// Recomputed per `page(_:)` rather than cached: this is a value type built fresh on every
    /// assembly, the work is a walk over at most `shelves.count × maxCardsPerShelf` strings (~290),
    /// and a stored property would have to be filled in `init` — the constructor-does-work shape
    /// that made `CardDetailModel` a main-thread stall.
    private var ordered: [String] {
        var out: [String] = []
        var seen: Set<String> = []
        var column = 0
        var more = true
        while more {
            more = false
            for shelf in shelves where column < shelf.cardIds.count {
                more = true
                let id = shelf.cardIds[column]
                if seen.insert(id).inserted { out.append(id) }
            }
            column += 1
        }
        return out
    }

    func page(_ index: Int) -> [CardRecord] {
        Self.page(index, ids: ordered, pageSize: pageSize, store: store)
    }

    /// Shared by `ForYouStream` and `ShelfStream`: slice the id list, read the records, and put them
    /// back in the caller's order — `cards(ids:)` returns rows in whatever order SQLite likes, and
    /// that order is the product decision here.
    static func page(_ index: Int, ids: [String], pageSize: Int, store: CatalogStore) -> [CardRecord] {
        let start = index * pageSize
        guard start < ids.count else { return [] }
        let slice = Array(ids[start..<min(start + pageSize, ids.count)])
        let byId = Dictionary(uniqueKeysWithValues: ((try? store.cards(ids: slice)) ?? []).map { ($0.id, $0) })
        return slice.compactMap { byId[$0] }
    }
}

/// One shelf, paged. Exists so a shelf's "See all" reuses the immersive `StreamView` deck verbatim
/// rather than reimplementing it — the deck already handles gestures, captions and quick actions,
/// and none of that should be forked.
struct ShelfStream: CardStream {
    let store: CatalogStore
    let shelf: Shelf
    var pageSize: Int = 12

    func page(_ index: Int) -> [CardRecord] {
        ForYouStream.page(index, ids: shelf.cardIds, pageSize: pageSize, store: store)
    }
}
