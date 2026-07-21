import Foundation

struct SetRecord: Identifiable, Equatable {
    let id: String
    let name: String
    let releaseDate: String?
    let total: Int
    let era: String?
    let repCardId: String?
}

struct PokemonRecord: Identifiable, Equatable {
    let dexId: Int
    let name: String
    let repCardId: String?
    var id: Int { dexId }
}

/// One attack from the catalog `card.attacks` JSON column (name + damage + energy cost).
/// Shown on the no-image placeholder so users can match a physical card without art.
struct Attack: Equatable, Codable {
    let name: String
    let damage: String? // printed damage, e.g. "30", "60+", "20×" — text, not numeric
    let cost: [String]  // energy type names, e.g. ["Grass", "Colorless"]
}

struct CardRecord: Identifiable, Equatable {
    let id: String
    let setId: String
    let number: String
    let name: String
    let hp: Int?
    let types: [String]
    let rarity: String?
    let artist: String?
    let imageBase: String?
    let imageUrl: String?
    let tcgplayerId: Int?
    // Default keeps the memberwise init source-compatible; catalogs older than the
    // attacks column (or non-Pokémon cards) simply have none.
    var attacks: [Attack] = []

    /// Prefer the TCGdex asset base (+ webp variant, e.g. "/high.webp"). When TCGdex has no art,
    /// derive the public TCGplayer-CDN image straight from the product id — same CDN sealed products
    /// use — so we serve nothing ourselves. `imageUrl` is a legacy last resort (older catalogs stored
    /// a re-hosted URL there; those are dead now, but a non-tcgplayer value would still be honored).
    func imageURL(quality: String) -> URL? {
        if let imageBase { return URL(string: "\(imageBase)/\(quality).webp") }
        if let tcgplayerId {
            // ponytail: two proven sizes (200w for grids, 800x800 for detail); add more if needed.
            let size = quality == "low" ? "200w" : "in_800x800"
            return URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/\(tcgplayerId)_\(size).jpg")
        }
        if let imageUrl { return URL(string: imageUrl) }
        return nil
    }
}

enum Grade: String, CaseIterable, Identifiable {
    // Declared ascending — code relies on allCases order for "lowest grade first" scans.
    case psa1, psa2, psa3, psa4, psa5, psa6, psa7, psa8, psa9, psa10
    var id: String { rawValue }
    var label: String { "PSA \(rawValue.dropFirst(3))" }
    var numeric: Int { Int(rawValue.dropFirst(3))! }
    init?(numeric: Int) { self.init(rawValue: "psa\(numeric)") }
}

/// Ungraded market price by card condition, from `price_by_condition` (raw PPT/marketplace
/// data — not gated like the PSA grades). rawValue matches the DB `condition` string exactly.
enum Condition: String, CaseIterable, Identifiable {
    case nearMint = "Near Mint"
    case lightlyPlayed = "Lightly Played"
    case moderatelyPlayed = "Moderately Played"
    case heavilyPlayed = "Heavily Played"
    case damaged = "Damaged"
    var id: String { rawValue }
    /// Short label for the price list: NM / LP / MP / HP / DMG.
    var label: String {
        switch self {
        case .nearMint: return "NM"
        case .lightlyPlayed: return "LP"
        case .moderatelyPlayed: return "MP"
        case .heavilyPlayed: return "HP"
        case .damaged: return "DMG"
        }
    }
}

/// Which lookback the app-wide price-change badges show. Persisted under the UserDefaults key
/// "deltaPeriod" — the `@AppStorage("deltaPeriod")` key in views is the single access path.
enum DeltaPeriod: String, CaseIterable {
    case d1 = "1d", d7 = "7d", d30 = "30d"
    var label: String {
        switch self {
        case .d1: return "yesterday"
        case .d7: return "last week"
        case .d30: return "last month"
        }
    }
    /// Compact segment label for `DeltaPeriodPicker` (finance shorthand: 1 day / 1 week / 1 month).
    var short: String {
        switch self {
        case .d1: return "1D"
        case .d7: return "1W"
        case .d30: return "1M"
        }
    }
    /// Tap-to-cycle order: yesterday → week → month → yesterday.
    var next: DeltaPeriod {
        switch self {
        case .d1: return .d7
        case .d7: return .d30
        case .d30: return .d1
        }
    }
}

/// One `price_delta` row: percent change of one priced thing (raw market, a PSA grade, a
/// condition, or a printing) over each packaged lookback. NULL column = no artifact covered
/// that window (or the price didn't exist then).
struct DeltaRecord: Equatable {
    enum Kind: String { case raw, psa, condition, printing, matrix }
    let kind: Kind
    let key: String        // "" | "1"…"10" | condition string | printing string
    let pct1d: Double?
    let pct7d: Double?
    let pct30d: Double?

    func pct(for period: DeltaPeriod) -> Double? {
        switch period {
        case .d1: return pct1d
        case .d7: return pct7d
        case .d30: return pct30d
        }
    }

    /// True when at least one lookback has a value. Lets a badge keep a tappable
    /// placeholder for a window this row happens to lack, so the app-wide period can
    /// always be cycled back to one that has data (never a persisted blank dead-end).
    var hasData: Bool { pct1d != nil || pct7d != nil || pct30d != nil }
}

struct ConditionPrice: Equatable, Identifiable {
    let condition: Condition
    let usd: Double
    var salesCount: Int? = nil    // rolled-up ungraded sales over the last 90 days; nil = no data
    var id: String { condition.rawValue }
}

/// Market price for one printing/finish of a card (from `price_by_variant`). `printing` is PPT's
/// key verbatim ("Normal", "Holofoil", "Reverse Holofoil", "1st Edition Holofoil", …).
struct VariantPrice: Equatable, Identifiable {
    let printing: String
    let usd: Double
    var id: String { printing }
}

/// Full printing×condition latest price (`price_matrix`) — the cross-product `variantPrices`/
/// `conditionPrices` each only give one axis of.
struct MatrixPrice: Equatable, Identifiable {
    let printing: String
    let condition: Condition
    let usd: Double
    var id: String { "\(printing)|\(condition.rawValue)" }
}

/// Graded price for one printing (`graded_by_printing`) — only distinct-product printings
/// (e.g. 1st Edition vs Unlimited) ever have rows. `grade` is PPT's key verbatim ("psa10", "cgc9").
struct GradedPrintingPrice: Equatable, Identifiable {
    let printing: String
    let grade: String
    let usd: Double
    var id: String { "\(printing)|\(grade)" }
}

/// One `graded_sales` row: how many real eBay sales back the graded price for `grade`
/// (PPT key verbatim, e.g. "psa10"/"cgc9"), plus PPT's smart-price confidence when present.
struct GradedSale: Equatable, Identifiable {
    var grade: String
    var salesCount: Int
    var confidence: String?
    var id: String { grade }
}

/// A sealed product — booster box, Elite Trainer Box, booster pack, tin, etc. — from the
/// `sealed_product` table (PPT sealed dataset). `setId` is PPT's set id and may not map 1:1 to
/// our card set ids, so the per-set section matches best-effort while the global browse is the
/// reliable surface. Empty everywhere until the pipeline starts populating the table.
struct SealedProduct: Identifiable, Equatable {
    let tcgplayerId: Int
    let name: String
    let setId: String?
    let productType: String?
    let marketUsd: Double?
    let lowUsd: Double?
    let asOf: String?
    var id: Int { tcgplayerId }

    /// TCGplayer product image, derived from the product id — the sealed feed carries no image URL.
    /// 200px suits a grid tile; a missing image just 404s and the tile shows a placeholder.
    var imageURL: URL? { URL(string: "https://tcgplayer-cdn.tcgplayer.com/product/\(tcgplayerId)_200w.jpg") }
}

/// A graded-population count for one grade (from the `population` table, PPT/GemRate data).
/// `totalPopulation`/`gemRate` repeat across a card's rows (per-grader summary values).
struct PopulationRow: Identifiable, Equatable {
    let grader: String
    let grade: String
    let count: Int
    let gemRate: Double?
    let totalPopulation: Int?
    var id: String { "\(grader)-\(grade)" }

    /// Grade with any leading "g" stripped and "_" restored to "." so labels read "PSA 10"/
    /// "PSA 9.5", never "PSA g10" or "PSA 9_5". The ingest paths disagree (bulk-export stores
    /// "10"/"9.5" or column-name "9_5"; the REST path stores "g10"), so normalizing at display
    /// covers all of them without a catalog rebuild.
    var displayGrade: String {
        (grade.hasPrefix("g") ? String(grade.dropFirst()) : grade)
            .replacingOccurrences(of: "_", with: ".")
    }
}

struct PriceRecord: Equatable {
    let cardId: String
    let rawUsd: Double?
    let rawEur: Double?
    let psa1: Double?
    let psa2: Double?
    let psa3: Double?
    let psa4: Double?
    let psa5: Double?
    let psa6: Double?
    let psa7: Double?
    let psa8: Double?
    let psa9: Double?
    let psa10: Double?
    let sellers: Int?
    let listings: Int?
    let lowUsd: Double?
    let asOf: String

    /// Grades default to nil so call sites name only the columns they care about. Labels must
    /// appear in ascending declaration order (Swift rule), matching how existing callers read.
    init(cardId: String, rawUsd: Double?, rawEur: Double?,
         psa1: Double? = nil, psa2: Double? = nil, psa3: Double? = nil, psa4: Double? = nil,
         psa5: Double? = nil, psa6: Double? = nil, psa7: Double? = nil, psa8: Double? = nil,
         psa9: Double? = nil, psa10: Double? = nil,
         sellers: Int? = nil, listings: Int? = nil, lowUsd: Double? = nil, asOf: String) {
        self.cardId = cardId; self.rawUsd = rawUsd; self.rawEur = rawEur
        self.psa1 = psa1; self.psa2 = psa2; self.psa3 = psa3; self.psa4 = psa4
        self.psa5 = psa5; self.psa6 = psa6; self.psa7 = psa7; self.psa8 = psa8
        self.psa9 = psa9; self.psa10 = psa10
        self.sellers = sellers; self.listings = listings; self.lowUsd = lowUsd; self.asOf = asOf
    }

    /// Default display currency is USD; a set grade falls back to raw_usd when that column is null.
    func value(for grade: Grade?) -> Double? {
        guard let grade else { return rawUsd }
        return gradedOnly(grade) ?? rawUsd
    }

    /// The graded column only — no raw fallback. For display with explicit gaps (spec §6).
    func gradedOnly(_ grade: Grade) -> Double? {
        switch grade {
        case .psa1: return psa1
        case .psa2: return psa2
        case .psa3: return psa3
        case .psa4: return psa4
        case .psa5: return psa5
        case .psa6: return psa6
        case .psa7: return psa7
        case .psa8: return psa8
        case .psa9: return psa9
        case .psa10: return psa10
        }
    }
}
