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
    /// The lock gate found a strong match it could not separate or could not corroborate against the
    /// OCR read. Carries the top four for the chooser — measured at 48 of 48 for containing the true
    /// card, so this is a near-guaranteed tap-to-resolve, not a failure.
    case ambiguous([String])
    case noMatch
}

struct LensCell: Identifiable, Equatable {
    let id: UUID
    /// Position in the source photo, so the cell can be outlined on it.
    let quad: CardQuad
    /// The upright rotation detection resolved for this cell. With `quad` it is everything needed to
    /// rebuild this exact plate later — which is what lets the expensive OCR run in the LAST stage
    /// without holding a 2.4 MB plate or re-running non-deterministic detection.
    var degrees: Int = 0
    /// ORB keypoints found. The best single predictor of "is this a card at all": phantom quads sit
    /// at a median of 15 against a real card's saturated 650.
    var fpCount: Int = 0
    /// Extrapolated into a pocket Vision returned no quad for, rather than detected.
    ///
    /// ⚠️ Load-bearing, not bookkeeping. A synthesised quad is a GUESS that a pocket is occupied, so it
    /// is kept only once it has actually identified — see `BinderPlan.place`. Measured on device
    /// 2026-08-09: an empty sleeve fingerprints at **442 and 595 keypoints**, nowhere near the ~15 a
    /// glare-band phantom gives, because the binder's woven fabric and the dot-textured plastic are
    /// real texture. So `minFpCount` does NOT distinguish an empty pocket from a card, and without this
    /// flag two empty pockets rendered as "a card here I couldn't read".
    var synthesized: Bool = false
    /// Set by pass A, independently of `state` — a card can be a known wishlist hit while pass B
    /// has not run yet.
    var onWishlist: Bool
    /// The wanted card pass A matched, kept rather than discarded. ⚠️ Without this the whole
    /// pass-A phase is unrenderable: `state` stays `.pending` until pass B lands, so a cell that
    /// is a known wishlist hit had no card id, produced no row, and the user saw "3 cards from
    /// your wishlist" over an empty list with no way to find out which.
    var wishlistCardId: String?
    var state: LensCellState

    init(id: UUID = UUID(), quad: CardQuad, degrees: Int = 0, fpCount: Int = 0,
         synthesized: Bool = false, onWishlist: Bool = false, wishlistCardId: String? = nil,
         state: LensCellState = .pending) {
        self.id = id; self.quad = quad; self.degrees = degrees; self.fpCount = fpCount
        self.synthesized = synthesized
        self.onWishlist = onWishlist
        self.wishlistCardId = wishlistCardId; self.state = state
    }

    /// The card this cell resolved to, if it is settled. `.ambiguous` deliberately has none — four
    /// candidates is not an answer, and showing the leader would be exactly the confident wrong
    /// answer the gate refused to give.
    var resolvedCardId: String? {
        if case .identified(let id, _) = state { return id }
        return nil
    }

    var chooserOptions: [String] {
        if case .ambiguous(let ids) = state { return ids }
        return []
    }

    /// Why this cell couldn't be read, verbatim ("reflection", "blur"). A cell in this state has NO
    /// fingerprint, so any keypoint-count test drops it — see `BinderModel.assignSlots`, where treating
    /// it as a phantom made a glare-blocked card render as an empty pocket.
    var unreadableReason: String? {
        if case .unreadable(let why) = state { return why }
        return nil
    }

    var isUnreadable: Bool { unreadableReason != nil }

    /// Pass B's answer once it exists, pass A's until then. Pass B wins when both are known: pass A
    /// only ever asked "is this one of my ~120 cards", so pass B searched a strictly larger set and
    /// its answer is the better-evidenced one.
    var cardId: String? {
        if case .identified(let id, _) = state { return id }
        return wishlistCardId
    }

    /// Records pass B's verdict and re-checks the wishlist claim against it.
    ///
    /// ⚠️ The re-check is not belt-and-braces. Pass B runs the same matcher at the same floor over
    /// a strictly larger candidate set, so its best can be a DIFFERENT card than pass A's — and
    /// without this the row shows pass B's card id under "On your wishlist" and sorts into the
    /// wishlist bucket, claiming the user wants a card they never asked for. A `.noMatch` keeps
    /// pass A's answer, and with it the flag.
    mutating func resolve(_ state: LensCellState, wanted: Set<String>) {
        self.state = state
        if let cardId { onWishlist = wanted.contains(cardId) }
    }
}
