import XCTest
@testable import TheTin

final class PokedexSortTests: XCTestCase {
    private let mons = [
        PokemonRecord(dexId: 3, name: "Venusaur", repCardId: nil),
        PokemonRecord(dexId: 1, name: "Bulbasaur", repCardId: nil),
        PokemonRecord(dexId: 2, name: "Ivysaur", repCardId: nil),
    ]
    func testDex() { XCTAssertEqual(PokedexSort.sorted(pokemon: mons, ownedCounts: [:], by: .dex).map(\.dexId), [1,2,3]) }
    func testAlphabetical() { XCTAssertEqual(PokedexSort.sorted(pokemon: mons, ownedCounts: [:], by: .alphabetical).map(\.name), ["Bulbasaur","Ivysaur","Venusaur"]) }
    func testMostOwned() {
        XCTAssertEqual(PokedexSort.sorted(pokemon: mons, ownedCounts: [1:0,2:5,3:2], by: .mostOwned).map(\.dexId), [2,3,1])
    }
}
