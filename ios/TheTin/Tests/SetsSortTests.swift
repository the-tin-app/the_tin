import XCTest
@testable import TheTin

final class SetsSortTests: XCTestCase {
    private func set(_ id: String, _ date: String) -> SetRecord {
        SetRecord(id: id, name: id, releaseDate: date, total: 10, era: nil, repCardId: nil)
    }
    private let sets = [
        SetRecord(id: "a", name: "a", releaseDate: "2020-01-01", total: 10, era: nil, repCardId: nil),
        SetRecord(id: "b", name: "b", releaseDate: "2022-01-01", total: 10, era: nil, repCardId: nil),
        SetRecord(id: "c", name: "c", releaseDate: "2021-01-01", total: 10, era: nil, repCardId: nil),
    ]
    func testRecent() {
        XCTAssertEqual(SetsListModel.sorted(sets: sets, rawTotals: [:], ownedCounts: [:], by: .recent).map(\.id), ["b","c","a"])
    }
    func testOldest() {
        XCTAssertEqual(SetsListModel.sorted(sets: sets, rawTotals: [:], ownedCounts: [:], by: .oldest).map(\.id), ["a","c","b"])
    }
    func testMostValuable() {
        let totals = ["a": 100.0, "b": 5.0, "c": 50.0]
        XCTAssertEqual(SetsListModel.sorted(sets: sets, rawTotals: totals, ownedCounts: [:], by: .mostValuable).map(\.id), ["a","c","b"])
    }
    func testMostOwned() {
        let owned = ["a": 1, "b": 9, "c": 4]
        XCTAssertEqual(SetsListModel.sorted(sets: sets, rawTotals: [:], ownedCounts: owned, by: .mostOwned).map(\.id), ["b","c","a"])
    }
}
