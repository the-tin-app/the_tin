import Foundation

struct CardGroup: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var sortOrder: Int
    var createdAt: Date
}

enum CardCondition: String, CaseIterable, Identifiable, Codable {
    case nm = "NM", lp = "LP", mp = "MP", hp = "HP", dmg = "DMG"
    var id: String { rawValue }
    /// The catalog `price_by_condition` key for this condition (rawValues intentionally match labels).
    var catalog: Condition {
        switch self {
        case .nm: return .nearMint
        case .lp: return .lightlyPlayed
        case .mp: return .moderatelyPlayed
        case .hp: return .heavilyPlayed
        case .dmg: return .damaged
        }
    }
}

/// Card finish/printing. Fixed list offered for every card (no per-card finish data exists yet).
/// Recorded on drafts and committed entries so future per-variant pricing lights up with no UI rework.
enum CardVariant: String, CaseIterable, Identifiable, Codable {
    case regular, holo, reverseHolo, firstEdition
    var id: String { rawValue }
    var label: String {
        switch self {
        case .regular: return "Regular"
        case .holo: return "Holo"
        case .reverseHolo: return "Reverse Holo"
        case .firstEdition: return "1st Edition"
        }
    }
    /// Cheap heuristic pre-fill from the catalog `rarity` string. Manual selection overrides this.
    static func defaultFor(rarity: String?) -> CardVariant {
        (rarity?.lowercased().contains("holo") ?? false) ? .holo : .regular
    }

    /// True when a PPT `price_by_variant.printing` key names this finish. Substring-tolerant
    /// because PPT keys vary ("Holofoil", "Reverse Holofoil", "1st Edition Holofoil"). Order-safe:
    /// each case's predicate excludes the others so `.holo` never swallows a reverse/1st-ed key.
    func matches(printing: String) -> Bool {
        let p = printing.lowercased()
        let firstEd = p.contains("1st edition") || p.contains("first edition")
        switch self {
        case .reverseHolo:  return p.contains("reverse")
        case .firstEdition: return firstEd
        case .holo:         return p.contains("holo") && !p.contains("reverse") && !firstEd
        // WotC-era keys say "Unlimited" instead of "Normal"; a non-holo unlimited is regular.
        case .regular:      return (p.contains("normal") && !p.contains("reverse"))
                                || (p.contains("unlimited") && !p.contains("holo"))
        }
    }

    /// This finish's market price among a card's printings, if PPT priced it.
    func price(in variants: [VariantPrice]) -> Double? {
        variants.first { matches(printing: $0.printing) }?.usd
    }
}

/// Where a committed scan lands. `.tin` = owned but ungrouped (groupId "").
enum RouteDestination: Equatable {
    case group(String)   // existing group id
    case newGroup(String) // name
    case tin
}

struct CollectionEntry: Identifiable, Equatable, Codable {
    var id: String
    var cardId: String        // REQUIRED by contract — server jobs read it
    var groupId: String       // "" = ungrouped (the Tin at large)
    var qty: Int
    var condition: String?    // CardCondition rawValue
    var grade: String?        // Grade rawValue ("psa3"…"psa10"); nil = raw/ungraded
    var pricePaid: Double?
    var gradingFeeUsd: Double? = nil   // what this copy actually cost to grade; user-recorded
    var acquiredAt: Date?
    var acquiredFrom: String? // card shop, show, trade, online, free text
    var addedAt: Date
    var variant: String? = nil // CardVariant rawValue; nil = unspecified
    /// Marked as available to trade. Optional (not `Bool = false`) so every collection.json
    /// written before this existed still decodes untouched.
    var forTrade: Bool? = nil

    /// When this copy left the collection — sold, traded away, given to a nephew.
    ///
    /// A card could enter the tin and never leave it: selling meant `deleteEntry`, which erased
    /// the row, and `PortfolioView`'s "Change vs. paid" is computed from the cost basis of the
    /// SURVIVING entries — so selling at a loss made that number *improve*, because the loss left
    /// the dataset along with the card. A sold copy keeps its history and its cost basis and
    /// stops counting toward what you own.
    var soldAt: Date? = nil
    /// What you got for it. nil for a trade or a gift, where there was no cash figure — the copy
    /// is still gone, we just can't say what it realised. USD, like `pricePaid` (OQ1).
    var soldFor: Double? = nil

    var isForTrade: Bool { forTrade == true }
    var isSold: Bool { soldAt != nil }

    var gradeValue: Grade? { grade.flatMap(Grade.init(rawValue:)) }
    var variantValue: CardVariant? { variant.flatMap(CardVariant.init(rawValue:)) }
    var conditionValue: CardCondition? { condition.flatMap(CardCondition.init(rawValue:)) }

    /// Nothing recorded about *how this copy was acquired* — so one such row is
    /// interchangeable with another and folding them into a quantity loses nothing.
    var hasAcquisitionDetail: Bool {
        pricePaid != nil || gradingFeeUsd != nil || acquiredAt != nil
            || !(acquiredFrom ?? "").isEmpty
    }

    /// True when `other` is the *same copy* as this one: same card, same divider, same printing,
    /// condition and grade — and neither side records how it was acquired. Adding a card you
    /// already own should become "×2", not a second indistinguishable ×1 row; but a copy with a
    /// price paid, a date, or a source is its own acquisition and stays its own row (merging it
    /// would silently destroy cost basis).
    ///
    /// `forTrade` IS compared (reversed 2026-07-25). It was excluded on the reasoning that the
    /// flag labels a stack of interchangeable cards; once the trade list became one row per
    /// physical copy — so you can keep one and trade the other three — a kept copy and a
    /// for-trade copy stopped being interchangeable. Leaving it out silently folded them back
    /// together on the next bulk move, destroying exactly the distinction the split creates.
    /// A sold copy is never the same copy as anything: it is a closed record, and folding a card
    /// you still own into one you've already sold would resurrect it in the totals while
    /// destroying what it realised. Belt and braces — sold rows are filtered out of
    /// `CollectionModel.entries`, which is the only pool the merge paths search — but this is the
    /// rule itself, and it should hold wherever the rule is asked.
    func isSameCopy(as other: CollectionEntry) -> Bool {
        !isSold && !other.isSold
            && cardId == other.cardId && groupId == other.groupId
            && condition == other.condition && grade == other.grade
            && variantValue == other.variantValue
            && isForTrade == other.isForTrade
            && !hasAcquisitionDetail && !other.hasAcquisitionDetail
    }
}
