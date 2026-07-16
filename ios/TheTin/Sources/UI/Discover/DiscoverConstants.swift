import Foundation

// VERIFIED against the production catalog v3 (generated 2026-07-06, sha256 a03a61fb…9d59883),
// pulled from Firebase Storage (catalog/manifest.json → catalog/catalog-v3.sqlite.gz) on 2026-07-07.
//
// Queries run against the real catalog (23,323 cards):
//
// -- SELECT rarity, COUNT(*) FROM card GROUP BY rarity ORDER BY 2 DESC;   (full-art tiers only)
//   Ultra Rare                 | 1500
//   Secret Rare                |  604      <- NOT "Rare Secret"
//   Illustration rare          |  482
//   Special illustration rare  |  216
//   Hyper rare                 |   74      <- the rainbow/gold tier; there is NO "Rare Rainbow"
//   (Full Art Trainer 6, Mega Hyper Rare 7, Shiny Ultra Rare 12 exist but are left out for now.)
//
// -- SELECT substr(number,1,2), COUNT(*) FROM card WHERE number GLOB '[A-Za-z]*' GROUP BY 1;
//   TG | 120   (Trainer Gallery, 4 SWSH sets × 30)   GG | 70 (Galarian Gallery, Crown Zenith)
//   → galleryNumberPrefixes ["TG","GG"] confirmed correct (other letter prefixes are promo/set codes).
//
// -- null-artist rate: 713 / 23323 (~3%) — fine for artist spotlights.
enum DiscoverConstants {
    /// Rarity strings (TCGdex verbatim) that count as full-art for the Full-art stream.
    /// Verified against production catalog v3 (see header).
    static let fullArtRarities: Set<String> = [
        "Illustration rare",
        "Special illustration rare",
        "Secret Rare",
        "Ultra Rare",
        "Hyper rare",
    ]

    /// Card-number prefixes that mark a curated gallery subset (Trainer / Galarian Gallery).
    /// Verified: TG=120, GG=70 present in production catalog v3.
    static let galleryNumberPrefixes: [String] = ["TG", "GG"]
}
