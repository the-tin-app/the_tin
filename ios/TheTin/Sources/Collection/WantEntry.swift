import Foundation

/// Priority of a wishlist card. Raw values are ordered so ascending sort = High first.
enum WantPriority: Int, Codable, CaseIterable, Identifiable {
    case high = 0, normal = 1, low = 2
    var id: Int { rawValue }

    /// An unrecognised priority decodes to `.normal` rather than throwing.
    ///
    /// **This exists to prevent silent, total loss of the wishlist.** Installing a build that
    /// predates a NEWER tier used to destroy `wants.json` with no error at all:
    /// `LocalWantsRepository.load` fails the dictionary decode on the unknown raw value, falls
    /// through to the legacy bare-id-array decode, fails that too, returns `[:]` — and the next
    /// write persists that empty map over the file. The user sees an empty wishlist and no warning.
    ///
    /// That mattered because "install build N−1 to check whether something regressed" is a routine
    /// move on this project, and because a tier was added at raw value `-1`. Forward-only decoding
    /// was an accepted trade for keeping 0/1/2 meaning what every stored wishlist already says; the
    /// *silent* part was nobody's decision.
    ///
    /// Downgrading still loses the tier LABEL on the older build, which is unavoidable — it has no
    /// case to put it in. But it now loses one field on one card instead of every card.
    ///
    /// Deliberately lenient about the wire type too: a priority that isn't even an integer is a
    /// corrupt file, and reading one card as Normal beats discarding the whole list.
    init(from decoder: any Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(Int.self)
        self = raw.flatMap(WantPriority.init(rawValue:)) ?? .normal
    }
    var label: String {
        switch self {
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        }
    }
}

/// One wishlist entry's per-card data. Every field defaults, so a plain `WantEntry()` is the
/// "just hearted it" state and legacy id-only wishlists migrate to it losslessly.
struct WantEntry: Codable, Hashable {
    var priority: WantPriority = .normal
    var targetUsd: Double? = nil
    var notes: String = ""
    var addedAt: Date = Date()
}
