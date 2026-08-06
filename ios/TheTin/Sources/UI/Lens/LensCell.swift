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
    var state: LensCellState

    init(id: UUID = UUID(), quad: CardQuad, onWishlist: Bool = false,
         state: LensCellState = .pending) {
        self.id = id; self.quad = quad; self.onWishlist = onWishlist; self.state = state
    }

    var cardId: String? {
        if case .identified(let id, _) = state { return id }
        return nil
    }
}
