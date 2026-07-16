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

    /// Prefer the TCGdex asset base (+ webp variant, e.g. "/high.webp"); otherwise fall back to
    /// the full mirrored image URL (a TCGplayer-CDN JPEG re-hosted in our bucket); else nil.
    func imageURL(quality: String) -> URL? {
        if let imageBase { return URL(string: "\(imageBase)/\(quality).webp") }
        if let imageUrl { return URL(string: imageUrl) }
        return nil
    }
}

enum Grade: String, CaseIterable, Identifiable {
    case psa3, psa7, psa9, psa10
    var id: String { rawValue }
    var label: String { "PSA \(rawValue.dropFirst(3))" }
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

struct ConditionPrice: Equatable, Identifiable {
    let condition: Condition
    let usd: Double
    var id: String { condition.rawValue }
}

/// Market price for one printing/finish of a card (from `price_by_variant`). `printing` is PPT's
/// key verbatim ("Normal", "Holofoil", "Reverse Holofoil", "1st Edition Holofoil", …).
struct VariantPrice: Equatable, Identifiable {
    let printing: String
    let usd: Double
    var id: String { printing }
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
    let psa3: Double?
    let psa7: Double?
    let psa9: Double?
    let psa10: Double?
    let asOf: String

    /// Default display currency is USD; a set grade falls back to raw_usd when that column is null.
    func value(for grade: Grade?) -> Double? {
        let graded: Double?
        switch grade {
        case .none: return rawUsd
        case .psa3: graded = psa3
        case .psa7: graded = psa7
        case .psa9: graded = psa9
        case .psa10: graded = psa10
        }
        return graded ?? rawUsd
    }

    /// The graded column only — no raw fallback. For display with explicit gaps (spec §6).
    func gradedOnly(_ grade: Grade) -> Double? {
        switch grade {
        case .psa3: return psa3
        case .psa7: return psa7
        case .psa9: return psa9
        case .psa10: return psa10
        }
    }
}
