import XCTest
@testable import TheTin

final class SetGoalsTests: XCTestCase {
    private static func card(_ id: String, _ number: String) -> CardRecord {
        CardRecord(id: id, setId: "s1", number: number, name: "Card \(number)", hp: nil, types: [],
                   rarity: nil, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }

    private func set(id: String = "s1", name: String = "Base Set", total: Int) -> SetRecord {
        SetRecord(id: id, name: name, releaseDate: "1999-01-09", total: total,
                  era: nil, repCardId: nil)
    }

    private var cards: [CardRecord] {
        [Self.card("s1-1", "1"), Self.card("s1-2", "2"), Self.card("s1-3", "3")]
    }

    func testGapIsWhatYouDontOwn() {
        let p = SetGoals.progress(set: set(total: 3), cards: cards, ownedCardIds: ["s1-1"],
                                  prices: ["s1-2": 10, "s1-3": 5])
        XCTAssertEqual(p.owned, 1)
        XCTAssertEqual(p.remaining, 2)
        XCTAssertEqual(p.gapValue, 15)
        XCTAssertFalse(p.isComplete)
    }

    /// Cheapest first: the next easy win should be at the top of the list, not buried under a
    /// chase card you're not buying today.
    func testMissingCardsAreCheapestFirst() {
        let p = SetGoals.progress(set: set(total: 3), cards: cards, ownedCardIds: [],
                                  prices: ["s1-1": 100, "s1-2": 1, "s1-3": 50])
        XCTAssertEqual(p.missingIds, ["s1-2", "s1-3", "s1-1"])
    }

    /// An unpriced card must not read as free — it's excluded from the total, and `pricedMissing`
    /// is what lets the UI say how much of the gap the number actually covers.
    func testUnpricedMissingCardsAreExcludedButCounted() {
        let p = SetGoals.progress(set: set(total: 3), cards: cards, ownedCardIds: [],
                                  prices: ["s1-1": 20])
        XCTAssertEqual(p.remaining, 3)
        XCTAssertEqual(p.pricedMissing, 1)
        XCTAssertEqual(p.gapValue, 20)
    }

    /// Secret rares push a set's card list past its printed total; "104/102 collected" reads as a
    /// bug, so owned is capped exactly as the sets grid and `GroupStats.setCompletion` cap it.
    func testOwnedIsCappedAtThePrintedTotal() {
        let p = SetGoals.progress(set: set(total: 2), cards: cards,
                                  ownedCardIds: ["s1-1", "s1-2", "s1-3"], prices: [:])
        XCTAssertEqual(p.owned, 2)
        XCTAssertEqual(p.total, 2)
        XCTAssertTrue(p.isComplete, "no cards missing, even though owned was capped")
    }

    /// "Collect this set" means every card the catalog lists — secret rares included — so a set
    /// isn't complete while one is missing, even once the printed total is reached.
    func testASecretRareStillCountsAsMissing() {
        let p = SetGoals.progress(set: set(total: 2), cards: cards,
                                  ownedCardIds: ["s1-1", "s1-2"], prices: ["s1-3": 400])
        XCTAssertEqual(p.owned, 2)
        XCTAssertFalse(p.isComplete)
        XCTAssertEqual(p.missingIds, ["s1-3"])
        XCTAssertEqual(p.gapValue, 400)
    }

    /// Closest to done first — those are the ones worth acting on. Finished sets sink rather than
    /// vanish, so completing one is visible instead of silent.
    func testSortPutsNearlyDoneFirstAndCompleteLast() {
        let rows = [
            // Complete: every card owned.
            SetGoals.progress(set: set(id: "done", name: "Done", total: 1),
                              cards: [Self.card("s1-1", "1")], ownedCardIds: ["s1-1"], prices: [:]),
            // A third of the way in.
            SetGoals.progress(set: set(id: "early", name: "Early", total: 3),
                              cards: cards, ownedCardIds: ["s1-1"], prices: [:]),
            // Two thirds — closest to finishing, so it should lead.
            SetGoals.progress(set: set(id: "nearly", name: "Nearly", total: 3),
                              cards: cards, ownedCardIds: ["s1-1", "s1-2"], prices: [:]),
        ]
        let sorted = SetGoals.sorted(rows)
        XCTAssertEqual(sorted.map { $0.set.id }, ["nearly", "early", "done"])
        XCTAssertTrue(sorted.last?.isComplete == true, "a finished set sinks to the bottom")
    }

    func testEmptySetGoalIsNotACrash() {
        let p = SetGoals.progress(set: set(total: 0), cards: [], ownedCardIds: [], prices: [:])
        XCTAssertEqual(p.fraction, 0)
        XCTAssertTrue(p.isComplete)
    }
}

@MainActor
final class SetGoalsModelTests: XCTestCase {
    private func tempModel() throws -> (SetGoalsModel, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("set-goals-\(UUID().uuidString).json")
        return (SetGoalsModel(paths: SetGoalPaths(fileURL: url)), url)
    }

    func testToggleAddsAndRemoves() throws {
        let (model, _) = try tempModel()
        XCTAssertFalse(model.isCollecting("base1"))
        model.toggle("base1")
        XCTAssertTrue(model.isCollecting("base1"))
        model.toggle("base1")
        XCTAssertFalse(model.isCollecting("base1"))
    }

    /// Goals have to survive a relaunch — the whole point is that you set one and forget it.
    func testGoalsPersistAcrossInstances() throws {
        let (model, url) = try tempModel()
        model.toggle("base1")
        model.toggle("swsh7")

        let reloaded = SetGoalsModel(paths: SetGoalPaths(fileURL: url))
        XCTAssertEqual(reloaded.setIds, ["base1", "swsh7"])
    }

    func testMissingFileLoadsEmptyRatherThanFailing() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-such-\(UUID().uuidString).json")
        XCTAssertTrue(SetGoalsModel(paths: SetGoalPaths(fileURL: url)).setIds.isEmpty)
    }
}
