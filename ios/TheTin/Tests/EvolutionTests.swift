import XCTest
import GRDB
@testable import TheTin

/// #197's evolution line: the pure walk over a `Lookup`, then the catalog queries behind it.
final class EvolutionTests: XCTestCase {
    private func mon(_ id: Int, _ name: String) -> PokemonRecord {
        PokemonRecord(dexId: id, name: name, repCardId: nil)
    }

    /// A tiny dex: Abra line, Oddish line (branches at Gloom), Eevee (branches at the root).
    private lazy var dex: [Int: PokemonRecord] = Dictionary(uniqueKeysWithValues: [
        mon(63, "Abra"), mon(64, "Kadabra"), mon(65, "Alakazam"),
        mon(43, "Oddish"), mon(44, "Gloom"), mon(45, "Vileplume"), mon(182, "Bellossom"),
        mon(133, "Eevee"), mon(134, "Vaporeon"), mon(135, "Jolteon"), mon(136, "Flareon"),
        mon(132, "Ditto"),
    ].map { ($0.dexId, $0) })
    private let parent: [Int: Int] = [64: 63, 65: 64, 44: 43, 45: 44, 182: 44, 134: 133, 135: 133, 136: 133]

    private var lookup: Evolution.Lookup {
        let (dex, parent) = (self.dex, self.parent)
        return Evolution.Lookup(
            species: { dex[$0] },
            evolvesFrom: { parent[$0].flatMap { dex[$0] } },
            evolvesInto: { id in parent.filter { $0.value == id }.keys.compactMap { dex[$0] } })
    }

    private func names(_ line: EvolutionLine?) -> [[String]] {
        line?.stages.map { $0.map(\.name) } ?? []
    }

    func testAMiddleStageShowsBothEnds() {
        let line = Evolution.line(for: 64, lookup: lookup)
        XCTAssertEqual(names(line), [["Abra"], ["Kadabra"], ["Alakazam"]])
        XCTAssertEqual(line?.current, 64)
    }

    func testALastStageShowsThePathThatLedToIt() {
        // Bellossom is Vileplume's sibling, not part of the line that led to it.
        XCTAssertEqual(names(Evolution.line(for: 45, lookup: lookup)), [["Oddish"], ["Gloom"], ["Vileplume"]])
    }

    func testABranchIsOneStageInDexOrder() {
        XCTAssertEqual(names(Evolution.line(for: 133, lookup: lookup)),
                       [["Eevee"], ["Vaporeon", "Jolteon", "Flareon"]])
        XCTAssertEqual(names(Evolution.line(for: 43, lookup: lookup)),
                       [["Oddish"], ["Gloom"], ["Vileplume", "Bellossom"]])
    }

    func testASpeciesThatDoesntEvolveHasNoLine() {
        XCTAssertNil(Evolution.line(for: 132, lookup: lookup))
        XCTAssertNil(Evolution.line(for: 9999, lookup: lookup), "unknown species")
    }

    /// A misprint that makes two species each other's pre-evolution must not loop or repeat.
    func testACycleIsCutNotWalked() {
        let a = mon(1, "A"), b = mon(2, "B")
        let cyclic = Evolution.Lookup(species: { [1: a, 2: b][$0] },
                                      evolvesFrom: { $0 == 1 ? b : a },
                                      evolvesInto: { $0 == 1 ? [b] : [a] })
        XCTAssertEqual(names(Evolution.line(for: 1, lookup: cyclic)), [["B"], ["A"]])
    }

    // MARK: catalog

    /// The fixture has no `detail` column and no Pokédex rows, so both are grafted on.
    private func catalog(withDetail: Bool = true) throws -> CatalogStore {
        let path = try FixtureCatalog.copyToTemp()
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
            INSERT INTO pokemon(dex_id, name) VALUES (63,'Abra'),(64,'Kadabra'),(65,'Alakazam'),(6,'Charizard'),
              (37,'Vulpix'),(38,'Ninetales');
            """)
            guard withDetail else { return }
            try db.execute(sql: "ALTER TABLE card ADD COLUMN detail TEXT")
            let cards: [(String, Int, String?)] = [
                ("t-abra", 63, nil),
                ("t-kadabra", 64, "Abra"),
                ("t-kadabra-dark", 64, "Abra"),
                ("t-alakazam", 65, "Kadabra"),
                ("t-alakazam-2", 65, "Kadabra"),
                ("t-alakazam-dark", 65, "Dark Kadabra"),   // the odd one out: majority still wins
                ("t-charizard-vmax", 6, "Charizard V"),     // same species, another mechanic
                ("t-ninetales-alola", 38, "Alolan Vulpix"), // prefixed form → its species
            ]
            for (id, dexId, from) in cards {
                let detail = from.map { #"{"stage":"Stage 1","evolveFrom":"\#($0)"}"# } ?? #"{"stage":"Basic"}"#
                try db.execute(sql: "INSERT INTO card(id, set_id, number, name, detail) VALUES (?, 'sv1', ?, ?, ?)",
                               arguments: [id, id, id, detail])
                try db.execute(sql: "INSERT INTO card_dex(card_id, dex_id) VALUES (?, ?)", arguments: [id, dexId])
            }
        }
        try q.close()
        return try CatalogStore(path: path)
    }

    func testTheCatalogReadsTheLineOffThePrintedCards() throws {
        let store = try catalog()
        XCTAssertEqual(names(store.evolutionLine(forDex: 63)), [["Abra"], ["Kadabra"], ["Alakazam"]])
        XCTAssertEqual(names(store.evolutionLine(forDex: 65)), [["Abra"], ["Kadabra"], ["Alakazam"]])
    }

    func testAPrefixedFormResolvesToItsSpecies() throws {
        XCTAssertEqual(names(try catalog().evolutionLine(forDex: 38)), [["Vulpix"], ["Ninetales"]])
    }

    /// "Charizard V" is not a species; a VMAX evolving from its own V is not a line to draw.
    func testAnEvolutionWithinOneSpeciesIsNoLine() throws {
        XCTAssertNil(try catalog().evolutionLine(forDex: 6))
    }

    /// A catalog from before the `detail` column: the queries throw, and the screen just has no row.
    func testACatalogWithoutDetailHasNoLines() throws {
        XCTAssertNil(try catalog(withDetail: false).evolutionLine(forDex: 64))
    }
}
