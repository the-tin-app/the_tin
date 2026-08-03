import Foundation

/// Priority of a wishlist card. Raw values are ordered so ascending sort = most wanted first.
/// `grail` is -1 rather than renumbering: 0/1/2 must keep meaning what every stored wishlist
/// and every written backup already says they mean.
enum WantPriority: Int, Codable, CaseIterable, Identifiable {
    case grail = -1, high = 0, normal = 1, low = 2
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
        case .grail: return "Grail"
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        }
    }
}

/// "I am buying this card." Deliberately separate from `WantPriority`: a grail you can't afford
/// yet isn't hunting, and a $40 card you're buying this week is hunting without being a grail.
/// Collapsing them forces a lie in one direction.
///
/// The budget is `WantEntry.targetUsd` — there is no second price field, because "the price
/// I'd pay for this" is what that field already means.
///
/// **No deadline (2026-08-01).** Hunts used to carry a 7/14/30-day `until` and expire on their
/// own. A card worth chasing can take six months, and a hunt shouldn't "just expire" — it ends
/// when you delete it. That trades a self-cleaning list for one you maintain, which is the
/// accepted cost; the old `isActive`/`daysLeft` arithmetic existed only to give a notification
/// something urgent to say, and there are no notifications any more.
///
/// A `Hunt` written by a build that stored `until` still decodes — Codable ignores the unknown
/// key. `WantEntryTests.testAHuntWrittenWithADeadlineStillDecodes` is the guard, and it matters
/// because a decode failure here empties the entire wishlist.
struct Hunt: Codable, Hashable {
    /// Worst condition you'd accept. "Anything but DMG" is `.hp`.
    var minCondition: CardCondition
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
