import XCTest
@testable import TheTin

final class SetsListModelTests: XCTestCase {
    private func set(_ id: String, era: String, date: String) -> SetRecord {
        SetRecord(id: id, name: id, releaseDate: date, total: 1, era: era, repCardId: nil)
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
