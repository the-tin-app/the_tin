import Foundation

/// One identified card, ready to show in the results list.
struct LensRow: Identifiable, Equatable {
    let id: UUID              // the cell's id — tapping a row jumps to it on its photo
    let photoId: UUID
    let cardId: String
    /// Resolved ONCE by the model from a batched `CatalogStore.cards(ids:)` and carried here, so
    /// the row view does no catalog I/O. A synchronous GRDB read inside a `List` row's `body` is
    /// re-run on every render of every visible row — the same mistake as the twelve synchronous
    /// reads that used to sit in `CardDetailModel.init`. nil only until pass B's names land.
    var name: String?
    let onWishlist: Bool
    let priceUsd: Double?
    let owned: Bool
}

struct LensFilter: Equatable {
    var wishlistOnly: Bool = false
    var hideOwned: Bool = false
    var maxPriceUsd: Double?
}

enum LensResults {

    /// Flattens every photo's identified cells into sorted rows.
    ///
    /// Sort: wishlist hits first, then price descending, then unpriced. Wishlist hits lead
    /// unconditionally — burying a $3 wanted card under a $200 one the user does not want inverts
    /// the whole feature.
    static func rows(photos: [UUID: [LensCell]],
                     prices: [String: Double],
                     owned: Set<String>,
                     names: [String: String] = [:]) -> [LensRow] {
        var out: [LensRow] = []
        // Photo order is not meaningful for the list (the photo overlay is where position matters),
        // but a stable order keeps the UI from reshuffling as later photos resolve.
        for (photoId, cells) in photos.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            for cell in cells {
                guard let cardId = cell.cardId else { continue }
                out.append(LensRow(id: cell.id, photoId: photoId, cardId: cardId,
                                   name: names[cardId], onWishlist: cell.onWishlist,
                                   priceUsd: prices[cardId], owned: owned.contains(cardId)))
            }
        }
        return out.sorted { a, b in
            if a.onWishlist != b.onWishlist { return a.onWishlist }
            switch (a.priceUsd, b.priceUsd) {
            case let (x?, y?): return x > y
            case (_?, nil):    return true      // priced before unpriced
            case (nil, _?):    return false
            case (nil, nil):   return a.cardId < b.cardId
            }
        }
    }

    static func apply(_ filter: LensFilter, to rows: [LensRow]) -> [LensRow] {
        rows.filter { row in
            if filter.wishlistOnly && !row.onWishlist { return false }
            if filter.hideOwned && row.owned { return false }
            if let cap = filter.maxPriceUsd {
                // An unknown price is NOT evidence of a low price. Showing unpriced cards under a
                // "$5 and under" filter would promise a bargain the app cannot see.
                guard let p = row.priceUsd, p <= cap else { return false }
            }
            return true
        }
    }
}
