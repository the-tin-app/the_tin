import Foundation
import XCTest
@testable import TheTin

enum FixtureCatalog {
    static func copyToTemp() throws -> String {
        let bundle = Bundle(for: BundleToken.self)
        guard let src = bundle.url(forResource: "catalog-fixture", withExtension: "sqlite") else {
            throw NSError(domain: "FixtureCatalog", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "fixture missing from test bundle"])
        }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: src, to: dst)
        return dst.path
    }

    static func make() throws -> CatalogStore { try CatalogStore(path: copyToTemp()) }

    // Real row from the fixture DB (verified: card sv1-25 "Pikachu", set sv1 printed total 198):
    static let knownCardId = "sv1-25"
    static let knownNumber = "25"
    static let knownTotal  = 198

    // set_info.printed_total (203) intentionally differs from total (237) on swsh7 — the
    // identical-art denominator tiebreaker case. sv1's printed_total (198) equals its total.
    static let printedTotalSetId = "swsh7"
    static let printedTotalValue = 203

    // card_twin synthetic identical-art pair (sv1-1 <-> sv1-25; both directions in the table).
    static let twinA = "sv1-1"
    static let twinB = "sv1-25"

    // card_text.body carries an attack-name token prepended to the effect text.
    static let attackNameCardId = "swsh7-215"
    static let attackNamePhrase = "Draconic Zenith"

    // Alphanumeric promo number (swsh7-TG20 "Charizard V") — proves CandidateIndex indexes the
    // RAW number string instead of collapsing non-numeric numbers to -1 via Int(c.number).
    static let promoCardId = "swsh7-TG20"
    static let promoNumber = "TG20"
}

private final class BundleToken {}
