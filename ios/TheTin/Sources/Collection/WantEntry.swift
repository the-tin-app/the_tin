import Foundation

/// Priority of a wishlist card. Raw values are ordered so ascending sort = most wanted first.
/// `grail` is -1 rather than renumbering: 0/1/2 must keep meaning what every stored wishlist
/// and every written backup already says they mean.
enum WantPriority: Int, Codable, CaseIterable, Identifiable {
    case grail = -1, high = 0, normal = 1, low = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .grail: return "Grail"
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        }
    }
}

/// "I am buying this card, within a window." Deliberately separate from `WantPriority`:
/// a grail you can't afford yet isn't hunting, and a $40 card you're buying Friday is
/// hunting without being a grail. Collapsing them forces a lie in one direction.
///
/// The budget is `WantEntry.targetUsd` — there is no second price field, because "the price
/// I'd pay for this" is what that field already means.
struct Hunt: Codable, Hashable {
    /// Worst condition you'd accept. "Anything but DMG" is `.hp`.
    var minCondition: CardCondition
    /// Absolute expiry, computed from the 7/14/30-day choice at save time.
    var until: Date

    /// Expiry is arithmetic, not a background job — there is no state to reconcile and
    /// nothing to clean up. This is the ONLY place the test is written.
    func isActive(now: Date = Date()) -> Bool { until >= now }
    var isActive: Bool { isActive() }
}

/// One wishlist entry's per-card data. Every field defaults, so a plain `WantEntry()` is the
/// "just hearted it" state and legacy id-only wishlists migrate to it losslessly.
struct WantEntry: Codable, Hashable {
    var priority: WantPriority = .normal
    var targetUsd: Double? = nil
    var notes: String = ""
    var addedAt: Date = Date()
    /// A real `Optional`, NOT a defaulted non-optional: a defaulted property still makes
    /// synthesized `Decodable` demand the key, which would silently fail to decode every
    /// wishlist written before this field existed.
    var hunt: Hunt? = nil
}
