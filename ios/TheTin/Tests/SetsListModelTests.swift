import XCTest
@testable import TheTin

final class SetsListModelTests: XCTestCase {
    private func set(_ id: String, era: String, date: String) -> SetRecord {
        SetRecord(id: id, name: id, releaseDate: date, total: 1, era: era, repCardId: nil)
    }

    private func card(_ id: String, setId: String) -> CardRecord {
        CardRecord(id: id, setId: setId, number: "1", name: id, hp: nil, types: [], rarity: nil,
                   artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }

    /// The sets grid used to count entries, so a raw + graded copy of one card read as 2/102
    /// while the set screen (GroupStats.setCompletion) said 1/102.
    func testOwnedCountsCountEachCardOnce() {
        let owned = [card("sv1-1", setId: "sv1"), card("sv1-1", setId: "sv1"),
                     card("sv1-2", setId: "sv1"), card("swsh1-9", setId: "swsh1")]

        XCTAssertEqual(SetsListModel.ownedCounts(ownedCards: owned), ["sv1": 2, "swsh1": 1])
    }

    func testMajorAndOtherGroupedByYear() {
        let sets = [
            set("sv1", era: "Scarlet & Violet", date: "2023-03-31"),
            set("swsh1", era: "Sword & Shield", date: "2020-02-07"),
            set("mcd21", era: "McDonald's Collection", date: "2021-01-05"),
            set("poc1", era: "Pokémon TCG Pocket", date: "2024-10-30"),
        ]
        let sections = SetsListModel.sections(sets: sets, rawTotals: [:], ownedCounts: [:], by: .recent)

        XCTAssertEqual(sections.map(\.category), [.major, .major, .other, .other])
        XCTAssertEqual(sections.filter { $0.category == .major }.map(\.year), ["2023", "2020"])
        XCTAssertEqual(sections.filter { $0.category == .other }.map(\.year), ["2024", "2021"])
        XCTAssertEqual(sections.filter { $0.isFirstOfCategory }.map(\.year), ["2023", "2024"])
    }
}
