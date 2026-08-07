import Foundation

/// One row of the binder's list view. Carries its slot, so the list always points back at the
/// physical object: you are standing in front of the binder and the answer to "which one" is
/// "page 2, row 1, column 3", not a scroll position.
struct BinderRow: Identifiable, Equatable {
    let slot: BinderSlot
    let cardId: String
    /// Resolved ONCE by the model from a batched `CatalogStore.cards(ids:)` and carried here, so the
    /// row view does no catalog I/O. A synchronous GRDB read inside a `List` row's `body` is re-run
    /// on every render of every visible row — the same mistake as the twelve synchronous reads that
    /// used to sit in `CardDetailModel.init`. The whole record travels because `CardImageView` needs
    /// `imageBase`/`tcgplayerId` to build an art URL.
    var card: CardRecord?
    var setName: String?
    let onWishlist: Bool
    let priceUsd: Double?
    let owned: Bool

    var id: BinderSlot { slot }
    /// The id until the batched read lands — never blank, so a row is never a mystery.
    var name: String { card?.name ?? cardId }

    /// "Page 1 · R2C3", 1-indexed because nobody counts pockets from zero.
    var position: String { "Page \(slot.page + 1) · R\(slot.row + 1)C\(slot.col + 1)" }
}

enum BinderSort: String, CaseIterable, Identifiable {
    case wishlistFirst, priceHighToLow, priceLowToHigh, name, set, slotOrder
    var id: String { rawValue }

    var label: String {
        switch self {
        case .wishlistFirst:  return "Wishlist first"
        case .priceHighToLow: return "Price, high to low"
        case .priceLowToHigh: return "Price, low to high"
        case .name:           return "Name"
        case .set:            return "Set"
        case .slotOrder:      return "Slot order"
        }
    }
}

struct BinderFilter: Equatable {
    var wishlistOnly = false
    var hideOwned = false
    var maxPriceUsd: Double?
    var setName: String?
    var sort: BinderSort = .wishlistFirst
}

enum BinderResults {

    /// Every resolved pocket, as rows. Unresolved pockets deliberately have none: a row with no card
    /// is not information, and the grid is where an unresolved pocket is visible and tappable.
    static func rows(_ scan: BinderScan, prices: [String: Double], cards: [String: CardRecord],
                     sets: [String: String], owned: Set<String>) -> [BinderRow] {
        scan.entries.compactMap { e in
            guard let cardId = e.cardId else { return nil }
            return BinderRow(slot: e.slot, cardId: cardId, card: cards[cardId],
                             setName: sets[cardId], onWishlist: e.onWishlist,
                             priceUsd: prices[cardId], owned: owned.contains(cardId))
        }
    }

    static func apply(_ filter: BinderFilter, to rows: [BinderRow]) -> [BinderRow] {
        let kept = rows.filter { row in
            if filter.wishlistOnly && !row.onWishlist { return false }
            if filter.hideOwned && row.owned { return false }
            if let set = filter.setName, row.setName != set { return false }
            if let cap = filter.maxPriceUsd {
                // An unknown price is NOT evidence of a low price. Showing unpriced cards under a
                // "$5 and under" filter would promise a bargain the app cannot see.
                guard let p = row.priceUsd, p <= cap else { return false }
            }
            return true
        }
        return sort(kept, by: filter.sort)
    }

    /// ⚠️ Every ordering ends in slot order, never "whatever the array held". Two cards at the same
    /// price in an unstable order reshuffle under the user's thumb as later pages resolve, and in a
    /// shop that reads as the app losing its place.
    private static func sort(_ rows: [BinderRow], by sort: BinderSort) -> [BinderRow] {
        switch sort {
        case .slotOrder:
            return rows.sorted { $0.slot < $1.slot }
        case .wishlistFirst:
            // Wishlist hits lead unconditionally, then dearest first: burying a $3 wanted card under
            // a $200 one the user does not want inverts the whole feature.
            return rows.sorted { a, b in
                if a.onWishlist != b.onWishlist { return a.onWishlist }
                return byPrice(a, b, descending: true)
            }
        case .priceHighToLow:
            return rows.sorted { byPrice($0, $1, descending: true) }
        case .priceLowToHigh:
            return rows.sorted { byPrice($0, $1, descending: false) }
        case .name:
            return rows.sorted { key($0.name, $0) < key($1.name, $1) }
        case .set:
            return rows.sorted { key($0.setName ?? "", $0) < key($1.setName ?? "", $1) }
        }
    }

    private static func key(_ text: String, _ row: BinderRow) -> (String, BinderSlot) {
        (text.lowercased(), row.slot)
    }

    /// Priced before unpriced in BOTH directions — an unknown price is not a cheap one, so it never
    /// heads a "low to high" list where it would look like the bargain of the binder.
    private static func byPrice(_ a: BinderRow, _ b: BinderRow, descending: Bool) -> Bool {
        switch (a.priceUsd, b.priceUsd) {
        case let (x?, y?):
            if x == y { return a.slot < b.slot }
            return descending ? x > y : x < y
        case (_?, nil):  return true
        case (nil, _?):  return false
        case (nil, nil): return a.slot < b.slot
        }
    }
}
