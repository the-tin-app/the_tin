import CoreGraphics
import Foundation

/// What we know about one card found in a photo. `pending` is the honest initial state — the cell
/// exists (we saw a card there) before we know what it is.
enum LensCellState: Equatable {
    case pending
    /// Told to the user verbatim, e.g. "reflection". Never a silent drop: a hidden miss makes the
    /// user distrust the answers the lens DID get right.
    case unreadable(String)
    case identified(cardId: String, inliers: Int)
    case noMatch
}

struct LensCell: Identifiable, Equatable {
    let id: UUID
    /// Position in the source photo, so the cell can be outlined on it.
    let quad: CardQuad
    /// Set by pass A, independently of `state` — a card can be a known wishlist hit while pass B
    /// has not run yet.
    var onWishlist: Bool
    /// The wanted card pass A matched, kept rather than discarded. ⚠️ Without this the whole
    /// pass-A phase is unrenderable: `state` stays `.pending` until pass B lands, so a cell that
    /// is a known wishlist hit had no card id, produced no row, and the user saw "3 cards from
    /// your wishlist" over an empty list with no way to find out which.
    var wishlistCardId: String?
    var state: LensCellState

    init(id: UUID = UUID(), quad: CardQuad, onWishlist: Bool = false,
         wishlistCardId: String? = nil, state: LensCellState = .pending) {
        self.id = id; self.quad = quad; self.onWishlist = onWishlist
        self.wishlistCardId = wishlistCardId; self.state = state
    }

    /// Pass B's answer once it exists, pass A's until then. The open set wins when both are known:
    /// pass A only ever asked "is this one of ~120 cards", so its answer is the narrower claim.
    var cardId: String? {
        if case .identified(let id, _) = state { return id }
        return wishlistCardId
    }
}
