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

extension CardCondition {
    /// How a buyer describes this as a *floor* ("I'll accept this or better"), which is not
    /// how the same value reads as a fact about a card you own. Shared by the wishlist edit
    /// sheet and the Hunting row so the two screens can't drift apart.
    var floorLabel: String {
        switch self {
        case .hp: return "Anything but DMG"
        case .lp: return "LP or better"
        case .nm: return "NM only"
        case .mp, .dmg: return rawValue
        }
    }
}

/// How a copy was printed — the four finishes, plus any print RUN the catalog names for that card.
///
/// It was an enum of exactly four cases. That was right while `price_by_variant` held seven PPT
/// finish keys and nothing else, and wrong the moment the catalog started naming print runs
/// ("Cosmos Holo", "World Championship Decks 2004", "Prize Pack Series Cards"): the substring
/// `matches` folds *every* one of those into `.holo` or `.regular`, so the card a collector
/// actually owns could not be recorded and was priced as the base card.
///
/// So it is a String now, with the four finishes as constants. Nothing about storage changed —
/// `CollectionEntry.variant` was already `String?` and this was already its rawValue, so an entry
/// written before this decodes to exactly what it did before and one written after is just a
/// longer string. There is no migration and no forward-decode hazard here.
struct CardVariant: RawRepresentable, Hashable, Identifiable, Codable {
    let rawValue: String
    var id: String { rawValue }

    static let regular = CardVariant(known: "regular")
    static let holo = CardVariant(known: "holo")
    static let reverseHolo = CardVariant(known: "reverseHolo")
    static let firstEdition = CardVariant(known: "firstEdition")
    /// The four finishes, in picker order. (Was `CaseIterable`; a print run is not a "case".)
    static let allCases: [CardVariant] = [.regular, .holo, .reverseHolo, .firstEdition]

    private init(known: String) { rawValue = known }

    /// Never fails — an unrecognised string IS a print run, which is the point. A catalog
    /// printing that names one of the four finishes canonicalises onto it, so "Holofoil" and
    /// "holo" are the same value and a CSV import round-trips exactly as it did before.
    init?(rawValue: String) {
        if let known = Self.allCases.first(where: { $0.rawValue == rawValue }) { self = known; return }
        if Self.pptPrintings.contains(where: { $0.caseInsensitiveCompare(rawValue) == .orderedSame }),
           let known = Self.allCases.first(where: { $0.matchesFinish(rawValue) }) { self = known; return }
        self.rawValue = rawValue
    }

    /// PPT's whole finish vocabulary, verbatim — the only `price_by_variant.printing` values that
    /// name a finish rather than a print run. Exact, because the substring test below cannot tell
    /// "Holofoil" (a finish) from "Cosmos Holo" (a print run) and answers `.holo` to both.
    private static let pptPrintings = ["Normal", "Unlimited", "Holofoil", "Unlimited Holofoil",
                                       "Reverse Holofoil", "1st Edition", "1st Edition Holofoil"]

    var label: String {
        switch self {
        case .regular: return "Regular"
        case .holo: return "Holo"
        case .reverseHolo: return "Reverse Holo"
        case .firstEdition: return "1st Edition"
        default: return rawValue   // a print run already reads as its own name
        }
    }

    /// Cheap heuristic pre-fill from the catalog `rarity` string. Manual selection overrides this.
    static func defaultFor(rarity: String?) -> CardVariant {
        (rarity?.lowercased().contains("holo") ?? false) ? .holo : .regular
    }

    /// True when a `price_by_variant.printing` key names this printing.
    ///
    /// For the four finishes this is the original substring test — PPT keys vary ("Holofoil",
    /// "1st Edition Holofoil") and it is load-bearing in `GroupStats` and the CSV import. For a
    /// print run it is exact: "Cosmos Holo" means that run and nothing else.
    func matches(printing: String) -> Bool {
        Self.allCases.contains(self)
            ? matchesFinish(printing)
            : printing.caseInsensitiveCompare(rawValue) == .orderedSame
    }

    /// Order-safe: each finish's predicate excludes the others, so `.holo` never swallows a
    /// reverse/1st-ed key.
    private func matchesFinish(_ printing: String) -> Bool {
        let p = printing.lowercased()
        let firstEd = p.contains("1st edition") || p.contains("first edition")
        switch self {
        case .reverseHolo:  return p.contains("reverse")
        case .firstEdition: return firstEd
        case .holo:         return p.contains("holo") && !p.contains("reverse") && !firstEd
        // WotC-era keys say "Unlimited" instead of "Normal"; a non-holo unlimited is regular.
        case .regular:      return (p.contains("normal") && !p.contains("reverse"))
                                || (p.contains("unlimited") && !p.contains("holo"))
        default:            return false
        }
    }

    /// The row that IS this printing, out of rows keyed by a printing name.
    ///
    /// Exact first, substring second — and the order is the whole point. A card can now carry both
    /// "Holofoil" and "Cosmos Holo", `matches` is true of BOTH for `.holo`, and every one of these
    /// tables arrives cheapest-first (`ORDER BY usd, printing`). Without the exact pass, a plain
    /// $40 holo would be valued at the $3 promo's price — in the tin total, the insurance report
    /// and the trade session alike.
    ///
    /// ⚠️ Use this, not `first { matches(printing:) }`, for anything keyed off `price_by_variant`
    /// or `price_delta` — those are the two tables print runs land in. `price_matrix` and
    /// `graded_by_printing` carry no print-run rows, so a bare `matches` is still correct there.
    func best<T>(in rows: [T], key: (T) -> String) -> T? {
        rows.first { CardVariant(rawValue: key($0)) == self } ?? rows.first { matches(printing: key($0)) }
    }

    func row(in variants: [VariantPrice]) -> VariantPrice? { best(in: variants) { $0.printing } }

    /// This printing's market price among a card's printings, if it is priced.
    func price(in variants: [VariantPrice]) -> Double? { row(in: variants)?.usd }
}

/// Where a committed scan lands. `.tin` = owned but ungrouped (groupId "").
enum RouteDestination: Equatable {
    case group(String)   // existing group id
    case newGroup(String) // name
    case tin
}

/// How a copy came into the collection.
///
/// The acquisition block assumed you bought the card — `pricePaid`, `acquiredAt`, `acquiredFrom`
/// — so "I pulled this from a pack I opened" could only be typed as prose into a free-text field.
/// This makes it a fact the app can read.
///
/// Optional on the entry: nil means NOT RECORDED, which is what every row written before this
/// existed says. Deliberately not "bought" — an unanswered question must never read as an answer.
enum AcquiredVia: String, Codable, CaseIterable, Identifiable {
    case bought, pulled, traded, gift
    var id: String { rawValue }

    /// Picker rows, where there's room to say what actually happened.
    var label: String {
        switch self {
        case .bought: return "Bought"
        case .pulled: return "Pulled from a pack"
        case .traded: return "Traded for"
        case .gift: return "Gift"
        }
    }

    /// The compact form for `sleeveText`, where this sits at the end of a
    /// "×2 · Reverse Holo · NM · Pulled" run and has to stay short.
    var shortLabel: String {
        switch self {
        case .bought: return "Bought"
        case .pulled: return "Pulled"
        case .traded: return "Traded"
        case .gift: return "Gift"
        }
    }
}

/// Your own photographs of ONE physical copy — filenames (never paths) under
/// `CardPhotos/<entryId>/`, so moving the container can't invalidate a stored reference.
///
/// Front and back are named because an insurer reads them as a pair; `details` is free-form for
/// the close-ups a condition claim actually turns on — a crease, a corner, a slab label.
struct EntryPhotos: Codable, Equatable {
    var front: String? = nil
    var back: String? = nil
    /// The rectified, margined picture the centring editor draws its lines on. A named slot
    /// rather than a separate store: `all`/`labelled` drive `PhotoStore.needed`, the iCloud
    /// mirror and the printed report, so hanging it here means backup and restore need no code
    /// of their own — and a measurement whose picture didn't survive a restore would be a number
    /// with nothing behind it.
    var centering: String? = nil
    /// Dense and capped at `maxDetails`. Dense so the form's tiles never show a hole.
    var details: [String] = []

    static let maxDetails = 2

    /// Which of the four tiles a photo belongs to. Defined here rather than in the view so the
    /// tile↔model mapping is testable without rendering anything.
    enum Slot: Hashable {
        case front, back, centering, detail(Int)
    }

    /// Every photo with the label the report prints under it, in print order. The single
    /// definition of ordering — `all` is derived from it so the two can never drift.
    ///
    /// ⚠️ Labels come from the SLOT, not the position: an entry with only a back photo must say
    /// "Back", not "Front".
    var labelled: [(label: String, file: String)] {
        var out: [(label: String, file: String)] = []
        if let front { out.append((label: "Front", file: front)) }
        if let back { out.append((label: "Back", file: back)) }
        if let centering { out.append((label: "Centering", file: centering)) }
        out += details.enumerated().map { (label: "Detail \($0.offset + 1)", file: $0.element) }
        return out
    }

    var all: [String] { labelled.map(\.file) }
    var isEmpty: Bool { all.isEmpty }

    func file(_ slot: Slot) -> String? {
        switch slot {
        case .front: return front
        case .back: return back
        case .centering: return centering
        case .detail(let i): return i < details.count ? details[i] : nil
        }
    }

    /// Set or clear one slot. Details append (never insert past the end) and removal closes the
    /// gap, which is what keeps `details` dense.
    mutating func set(_ file: String?, _ slot: Slot) {
        switch slot {
        case .front: front = file
        case .back: back = file
        case .centering: centering = file
        case .detail(let i):
            if let file {
                if i < details.count { details[i] = file }
                else if details.count < Self.maxDetails { details.append(file) }
            } else if i < details.count {
                details.remove(at: i)
            }
        }
    }
}

/// One sealed product you own — a booster box, an Elite Trainer Box, a tin off the shelf.
///
/// Deliberately NOT a `CollectionEntry`. That type is `cardId`-keyed and carries condition, grade
/// and printing, none of which mean anything for a shrink-wrapped box; bending it to fit would
/// have put four meaningless fields on every sealed row and a required card id it can never have.
/// What the two genuinely share is the acquisition block, and that is exactly what this mirrors.
///
/// `productId` is `sealed_product.tcgplayer_id` — the same key `SealedProduct.id` uses, so the
/// catalog join is a dictionary lookup and the CSV round-trip has a stable identifier to write.
///
/// There is no "opened" state, by decision: opening a box is a delete, or a quantity decrement.
struct SealedEntry: Identifiable, Equatable, Codable {
    var id: String
    var productId: Int
    var qty: Int
    var pricePaid: Double? = nil
    var acquiredAt: Date? = nil
    var acquiredFrom: String? = nil
    /// `AcquiredVia` rawValue; nil = not recorded. Same contract as `CollectionEntry.acquiredVia`
    /// — an unanswered question must never read as an answer.
    var acquiredVia: String? = nil
    var addedAt: Date
    /// When this box left — sold, traded away, or opened. Same contract as
    /// `CollectionEntry.soldAt`: the row keeps its cost basis and stops counting toward what you
    /// own, so selling at a loss can't improve the numbers by removing itself from them.
    var soldAt: Date? = nil
    var soldFor: Double? = nil

    var isSold: Bool { soldAt != nil }
    var acquiredViaValue: AcquiredVia? { acquiredVia.flatMap(AcquiredVia.init(rawValue:)) }
}

extension Array where Element == SealedEntry {
    /// Physical box count = Σ qty, sold boxes excluded — the sealed mirror of `cardCount`.
    var boxCount: Int { lazy.filter { !$0.isSold }.reduce(0) { $0 + $1.qty } }

    /// Boxes of ONE product you own — what the browse tile's badge counts.
    ///
    /// Summed across entries rather than read off one: "Add to tin" twice makes two rows for the
    /// same product (each with its own price paid), so a tile reading "1" while the tin listed two
    /// would be the browse screen contradicting the tin.
    func boxCount(productId: Int) -> Int {
        lazy.filter { !$0.isSold && $0.productId == productId }.reduce(0) { $0 + $1.qty }
    }

    /// What the sealed you still own is worth: `market_usd × qty`, sold boxes excluded.
    ///
    /// A product the catalog no longer prices contributes NOTHING rather than zero — the same rule
    /// the card totals follow — and `priced` reports how many of `boxes` were actually valued, so
    /// the UI can admit the gap instead of implying full coverage.
    func marketValue(products: [Int: SealedProduct]) -> (total: Double, priced: Int, boxes: Int) {
        var total = 0.0, priced = 0, boxes = 0
        for entry in self where !entry.isSold {
            boxes += entry.qty
            guard let usd = products[entry.productId]?.marketUsd else { continue }
            total += usd * Double(entry.qty)
            priced += entry.qty
        }
        return (total, priced, boxes)
    }
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

    /// How this copy was acquired — `AcquiredVia` rawValue; nil = not recorded.
    ///
    /// A real Optional, not a defaulted non-optional: a defaulted property still makes
    /// synthesized `Decodable` DEMAND the key, so every collection.json written before this
    /// existed would fail to decode. Same convention as `forTrade`, `soldAt` and `soldFor`.
    var acquiredVia: String? = nil

    /// Your own photographs of this copy. A real `Optional` for the reason `acquiredVia`
    /// documents above — a defaulted non-optional makes synthesized `Decodable` demand the key.
    var photos: EntryPhotos? = nil

    /// Border ratios for this copy, placed by hand in the centring editor. Optional for the same
    /// decode reason as `photos`. Being on the entry is what puts it in `collection.json`, which
    /// IS the backup snapshot — so it restores with everything else and needs no separate path.
    var centering: Centering? = nil

    var isForTrade: Bool { forTrade == true }
    var isSold: Bool { soldAt != nil }

    var gradeValue: Grade? { grade.flatMap(Grade.init(rawValue:)) }
    var variantValue: CardVariant? { variant.flatMap(CardVariant.init(rawValue:)) }
    var conditionValue: CardCondition? { condition.flatMap(CardCondition.init(rawValue:)) }
    var acquiredViaValue: AcquiredVia? { acquiredVia.flatMap(AcquiredVia.init(rawValue:)) }

    /// Nothing recorded about *how this copy was acquired* — so one such row is
    /// interchangeable with another and folding them into a quantity loses nothing.
    ///
    /// `acquiredVia` is deliberately NOT here. This gate protects per-copy facts (a price, a
    /// fee, a date, a seller); a bare source label is a property of the whole stack. Four
    /// energies out of one pack are still four interchangeable cards and must fold into ×4.
    var hasAcquisitionDetail: Bool {
        pricePaid != nil || gradingFeeUsd != nil || acquiredAt != nil
            || !(acquiredFrom ?? "").isEmpty
            // A photograph is a per-copy fact. Without this clause `isSameCopy` folds a
            // photographed copy into a ×2 on the next bulk move and the photo link is destroyed
            // silently — the same failure the `forTrade` comparison was added to prevent.
            // Deliberately `isEmpty`, not `!= nil`: opening the form and backing out must not
            // permanently split a stack.
            || !(photos?.isEmpty ?? true)
            // Centring is measured from one physical copy's own borders. Folding a measured copy
            // into a x2 would attach its ratios to a card nobody measured — the same silent
            // destruction the photo clause above prevents.
            || centering != nil
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
    ///
    /// `acquiredVia` IS compared, for the same reason and to avoid the same bug: a copy you
    /// pulled and a copy you bought are not interchangeable, and merging them destroys the
    /// provenance silently. Compared as the parsed enum, not the raw string, so an unreadable
    /// value is "not recorded" on both sides rather than a distinct third thing.
    func isSameCopy(as other: CollectionEntry) -> Bool {
        !isSold && !other.isSold
            && cardId == other.cardId && groupId == other.groupId
            && condition == other.condition && grade == other.grade
            && variantValue == other.variantValue
            && isForTrade == other.isForTrade
            && acquiredViaValue == other.acquiredViaValue
            && !hasAcquisitionDetail && !other.hasAcquisitionDetail
    }
}
