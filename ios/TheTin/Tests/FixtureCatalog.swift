import Foundation
import GRDB
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

    // Synthetic sealed products grafted onto a copy of the fixture. The shipped fixture predates
    // sealed ownership and carries no `sealed_product` table at all, so a matcher built over it
    // can never resolve a sealed row — every sealed import test would otherwise pass for the
    // wrong reason. The last two share a name across two sets on purpose: that's the ambiguity
    // case the matcher has to refuse rather than guess.
    static let sealedBoosterBoxId = 517_898
    static let sealedETBId = 517_899
    static let sealedAmbiguousName = "Collector Chest"

    static func makeWithSealed() throws -> CatalogStore {
        let path = try copyToTemp()
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            // IF NOT EXISTS + DELETE, not CREATE: the shipped fixture already carries a
            // `sealed_product` table with its own rows. These tests assert on exact ids and on a
            // deliberately-ambiguous name, so the table has to hold these rows and only these.
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sealed_product(tcgplayer_id INTEGER PRIMARY KEY,
              name TEXT NOT NULL, set_id TEXT, product_type TEXT, market_usd REAL, low_usd REAL,
              as_of TEXT);
            DELETE FROM sealed_product;
            INSERT INTO sealed_product VALUES
              (\(sealedBoosterBoxId),'Evolving Skies Booster Box','swsh7','Booster Box',500.0,450.0,'2026-07-13'),
              (\(sealedETBId),'Evolving Skies Elite Trainer Box','swsh7','Elite Trainer Box',59.99,52.0,'2026-07-13'),
              (600001,'\(sealedAmbiguousName)','swsh7','Collector Chest',39.99,NULL,'2026-07-13'),
              (600002,'\(sealedAmbiguousName)','sv1','Collector Chest',34.99,NULL,'2026-07-13');
            """)
        }
        try q.close()
        return try CatalogStore(path: path)
    }

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
