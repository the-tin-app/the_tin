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
}
