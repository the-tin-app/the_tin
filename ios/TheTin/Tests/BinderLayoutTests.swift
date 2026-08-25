import XCTest
@testable import TheTin

final class BinderLayoutTests: XCTestCase {
    private func card(_ id: String, _ variant: String? = nil) -> PlannedCard {
        PlannedCard(cardId: id, variant: variant)
    }

    func testAShapeClampsToOneThroughFive() {
        XCTAssertEqual(PageShape(rows: 0, cols: 9), PageShape(rows: 1, cols: 5))
        XCTAssertEqual(PageShape(rows: 1, cols: 1).pockets, 1)
        XCTAssertEqual(PageShape(rows: 3, cols: 4).pockets, 12)
    }

    /// A page with no shape of its own uses the binder's.
    func testAPageWithoutAShapeUsesTheBinderDefault() {
        let layout = BinderLayout(groupId: "g", shape: PageShape(rows: 3, cols: 3),
                                  pages: [BinderPage(), BinderPage(shape: PageShape(rows: 1, cols: 1))])
        XCTAssertEqual(layout.capacities, [9, 1])
    }

    /// A truncated or hand-edited file must not index out of range later. `binders.json` and a
    /// restored backup are both trust boundaries.
    func testNormalizeResizesEverySlotArrayToItsOwnShape() {
        let layout = BinderLayout(groupId: "g", shape: PageShape(rows: 2, cols: 2), pages: [
            BinderPage(slots: []),                                            // short
            BinderPage(slots: Array(repeating: card("a"), count: 99)),        // long
            BinderPage(shape: PageShape(rows: 1, cols: 1), slots: []),        // short, overridden
        ]).normalized()
        XCTAssertEqual(layout.pages.map(\.slots.count), [4, 4, 1])
        XCTAssertEqual(layout.pages[1].slots.compactMap { $0 }.count, 4)
    }

    /// A page with its own shape is a WALL: the run stops at it, which is what stops a shift from
    /// pushing a card into a 1×1 showcase page.
    func testARunStopsAtAPageWithItsOwnShape() {
        let layout = BinderLayout(groupId: "g", shape: .default, pages: [
            BinderPage(), BinderPage(), BinderPage(shape: PageShape(rows: 1, cols: 1)), BinderPage(),
        ]).normalized()
        XCTAssertEqual(layout.run(containing: 0), 0..<2)
        XCTAssertEqual(layout.run(containing: 1), 0..<2)
        XCTAssertEqual(layout.run(containing: 2), 2..<3, "an overridden page is its own run")
        XCTAssertEqual(layout.run(containing: 3), 3..<4)
    }

    func testChunkFillsWholePagesAndPadsTheLast() {
        let pages = BinderLayout.chunk([card("a"), card("b"), card("c")], shape: PageShape(rows: 1, cols: 2))
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].slots.compactMap { $0?.cardId }, ["a", "b"])
        XCTAssertEqual(pages[1].slots.count, 2)
        XCTAssertEqual(pages[1].slots.compactMap { $0?.cardId }, ["c"])
    }

    private func run(_ ids: [String?], shape: PageShape = PageShape(rows: 1, cols: 2)) -> BinderLayout {
        BinderLayout(groupId: "g", shape: shape,
                     pages: BinderLayout.chunk(ids.map { $0.map { PlannedCard(cardId: $0) } }, shape: shape))
    }

    private func flat(_ layout: BinderLayout) -> [String?] {
        layout.pages.flatMap { $0.slots }.map { $0?.cardId }
    }

    func testPlaceOverwritesOnePocketAndShiftsNothing() {
        var layout = run(["a", "b", "c", "d"])
        layout.place(PlannedCard(cardId: "z"), page: 0, index: 1)
        XCTAssertEqual(flat(layout), ["a", "z", "c", "d"])
    }

    func testInsertShiftsEverythingAfterItAlong() {
        var layout = run(["a", "b", "c", nil])
        layout.insert(PlannedCard(cardId: "z"), page: 0, index: 1)
        XCTAssertEqual(flat(layout), ["a", "z", "b", "c"])
    }

    /// Overflow appends a page rather than dropping the card off the end.
    func testInsertAppendsAPageWhenTheRunIsFull() {
        var layout = run(["a", "b", "c", "d"])
        layout.insert(PlannedCard(cardId: "z"), page: 0, index: 0)
        XCTAssertEqual(layout.pages.count, 3)
        XCTAssertEqual(flat(layout), ["z", "a", "b", "c", "d", nil])
    }

    /// The rule that protects a solo showcase page.
    func testInsertNeverPushesACardIntoAnOverriddenPage() {
        var layout = BinderLayout(groupId: "g", shape: PageShape(rows: 1, cols: 2), pages: [
            BinderPage(slots: [PlannedCard(cardId: "a"), PlannedCard(cardId: "b")]),
            BinderPage(shape: PageShape(rows: 1, cols: 1), slots: [PlannedCard(cardId: "solo")]),
        ])
        layout.insert(PlannedCard(cardId: "z"), page: 0, index: 0)
        XCTAssertEqual(layout.pages.count, 3, "the new page lands INSIDE the run, before the solo page")
        XCTAssertEqual(flat(layout), ["z", "a", "b", nil, "solo"])
        XCTAssertEqual(layout.pages[2].shape, PageShape(rows: 1, cols: 1),
                       "the solo page keeps its shape and its card")
    }

    func testTheMoveCountCountsOnlyPlannedCardsAfterThePocket() {
        let layout = run(["a", "b", nil, "d"])
        XCTAssertEqual(layout.moveCount(page: 0, index: 0), 3, "an empty pocket in the middle moves nothing")
        XCTAssertEqual(layout.moveCount(page: 1, index: 1), 1, "only 'd' is at or after this pocket")
    }

    /// Pages read 1-indexed to a human; the model is 0-indexed. Nil when nothing moves, so the
    /// sheet can omit the whole row rather than say "0 cards move".
    func testTheMoveSummaryReadsInHumanPageNumbers() {
        let layout = run(["a", "b", "c", nil])
        XCTAssertEqual(layout.moveSummary(page: 0, index: 1), "2 cards move · pages 1–2")
        XCTAssertNil(layout.moveSummary(page: 1, index: 1), "nothing follows the last empty pocket")
    }

    private func record(_ id: String, number: String) -> CardRecord {
        CardRecord(id: id, setId: "sv02", number: number, name: id, hp: nil, types: [],
                   rarity: nil, artist: nil, imageBase: nil, imageUrl: nil, tcgplayerId: nil)
    }

    func testTheGeneratorKeepsCatalogOrderOnePocketPerCard() {
        let pages = BinderLayout.pages(for: [record("a", number: "1"), record("b", number: "2")],
                                       shape: PageShape(rows: 1, cols: 3), reverseHoloFor: [])
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].slots.compactMap { $0?.cardId }, ["a", "b"])
        XCTAssertEqual(pages[0].slots.count, 3, "the last page is padded, not short")
    }

    /// The master-set knob: a second pocket right after the card, only for cards that actually
    /// have a reverse-holo printing.
    func testReverseHolosFollowTheirCardAndOnlyWhenEligible() {
        let pages = BinderLayout.pages(for: [record("a", number: "1"), record("b", number: "2")],
                                       shape: PageShape(rows: 1, cols: 3), reverseHoloFor: ["a"])
        let planned = pages.flatMap { $0.slots }.compactMap { $0 }
        XCTAssertEqual(planned.map(\.cardId), ["a", "a", "b"])
        XCTAssertEqual(planned.map(\.variant), [nil, CardVariant.reverseHolo.rawValue, nil])
    }

    /// The screen counts pages from 1; the model counts from 0. That boundary rots silently, so
    /// it is pinned here rather than left to a view nobody can unit-test.
    func testPageLabelsAreOneIndexedForHumans() {
        let layout = run(["a", "b", "c", "d"])
        XCTAssertEqual(BinderLayoutView.pageLabel(index: 0, of: layout), "Page 1 of 2")
        XCTAssertEqual(BinderLayoutView.pageLabel(index: 1, of: layout), "Page 2 of 2")
    }

    func testThePageIndexClampsIntoRange() {
        XCTAssertEqual(BinderLayoutView.clamped(5, pages: 2), 1)
        XCTAssertEqual(BinderLayoutView.clamped(-3, pages: 2), 0)
        XCTAssertEqual(BinderLayoutView.clamped(0, pages: 0), 0, "an empty layout must not produce -1")
    }

    /// The branch that decides whether a shape change is confirmed or applied silently. Getting it
    /// wrong in the lenient direction destroys hand-placed work behind a picker.
    func testAShapeChangeOnlyCountsPlannedCardsItWouldActuallyDrop() {
        let full = BinderPage(slots: [card("a"), card("b"), card("c"), card("d")])
        XCTAssertEqual(BinderLayoutView.loss(in: full, changingTo: PageShape(rows: 1, cols: 1),
                                             default: .default), 3)
        XCTAssertEqual(BinderLayoutView.loss(in: full, changingTo: PageShape(rows: 3, cols: 3),
                                             default: .default), 0, "growing loses nothing")
        let gappy = BinderPage(slots: [card("a"), nil, nil, nil])
        XCTAssertEqual(BinderLayoutView.loss(in: gappy, changingTo: PageShape(rows: 1, cols: 1),
                                             default: .default), 0,
                       "empty pockets are not a loss — this is what keeps a lossless resize one tap")
        XCTAssertEqual(BinderLayoutView.loss(in: full, changingTo: nil,
                                             default: PageShape(rows: 1, cols: 2)), 2,
                       "clearing the override falls back to the binder's own shape")
    }

    /// The invariant setup owns: `place`/`insert` are silent no-ops on a page that does not
    /// exist, so a created-but-pageless binder is a screen of dead taps. `BinderLayout.pages`
    /// really does return `[]` for no cards — asserted first here so this is a guard and not a
    /// tautology — which is what a set the catalog holds no cards for would produce.
    func testANewLayoutAlwaysGetsAtLeastOnePage() {
        XCTAssertTrue(BinderLayout.pages(for: [], shape: .default, reverseHoloFor: []).isEmpty,
                      "the generator this guards still returns no pages for no cards")
        XCTAssertEqual(BinderSetupSheet.initialPages(cards: [], shape: .default,
                                                     reverseHoloFor: []).count, 1)
        XCTAssertEqual(BinderSetupSheet.initialPages(cards: [], shape: PageShape(rows: 1, cols: 1),
                                                     reverseHoloFor: []).count, 1)
        // The starting page survives the round trip through `save`, sized to its shape.
        let saved = BinderLayout(groupId: "g", shape: PageShape(rows: 2, cols: 2),
                                 pages: BinderSetupSheet.initialPages(
                                    cards: [], shape: PageShape(rows: 2, cols: 2),
                                    reverseHoloFor: [])).normalized()
        XCTAssertEqual(saved.pages.map(\.slots.count), [4])
    }

    /// Cards present: the guard steps out of the way entirely.
    func testSetupPassesRealCardsStraightToTheGenerator() {
        let cards = [record("a", number: "1"), record("b", number: "2")]
        let shape = PageShape(rows: 1, cols: 1)
        XCTAssertEqual(BinderSetupSheet.initialPages(cards: cards, shape: shape, reverseHoloFor: []),
                       BinderLayout.pages(for: cards, shape: shape, reverseHoloFor: []))
    }

    func testReverseHoloEligibilityReadsThePrintingNames() {
        let priced = ["a": [VariantPrice(printing: "Reverse Holofoil", usd: 1)],
                      "b": [VariantPrice(printing: "Normal", usd: 1)]]
        XCTAssertEqual(BinderLayout.reverseHoloEligible(in: priced), ["a"])
    }
}
