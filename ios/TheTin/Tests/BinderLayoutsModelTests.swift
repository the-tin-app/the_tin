import XCTest
@testable import TheTin

@MainActor
final class BinderLayoutsModelTests: XCTestCase {
    private func tempPaths() -> BinderPaths {
        BinderPaths(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binders-\(UUID().uuidString).json"))
    }

    private func sample(_ groupId: String) -> BinderLayout {
        BinderLayout(groupId: groupId, shape: PageShape(rows: 1, cols: 2),
                     pages: [BinderPage(slots: [PlannedCard(cardId: "a"), nil])])
    }

    func testAMissingFileIsAnEmptyModelNotAFailure() {
        XCTAssertTrue(BinderLayoutsModel(paths: tempPaths()).layouts.isEmpty)
    }

    func testALayoutSurvivesARelaunch() throws {
        let paths = tempPaths()
        let model = BinderLayoutsModel(paths: paths)
        model.save(sample("g1"))
        let reloaded = BinderLayoutsModel(paths: paths)
        XCTAssertEqual(reloaded.layout(for: "g1"), sample("g1"))
    }

    func testRemoveDropsOneLayoutAndLeavesTheRest() throws {
        let paths = tempPaths()
        let model = BinderLayoutsModel(paths: paths)
        model.save(sample("g1"))
        model.save(sample("g2"))
        model.remove(groupId: "g1")
        XCTAssertNil(BinderLayoutsModel(paths: paths).layout(for: "g1"))
        XCTAssertNotNil(BinderLayoutsModel(paths: paths).layout(for: "g2"))
    }

    /// The `WantEntry` lesson: a file written by another build must not take the whole thing down.
    /// An unknown key is ignored; a layout that cannot be read at all is dropped alone.
    func testAFileWithAnUnknownKeyStillDecodes() throws {
        let paths = tempPaths()
        let json = """
        [{"groupId":"g1","shape":{"rows":1,"cols":2},"pages":[{"slots":[{"cardId":"a"},null]}],\
        "somethingFromTheFuture":true}]
        """
        try Data(json.utf8).write(to: paths.fileURL)
        XCTAssertEqual(BinderLayoutsModel(paths: paths).layout(for: "g1")?.pages.first?.slots.count, 2)
    }

    /// Load normalizes, so a short slot array from any source cannot index out of range later.
    func testLoadResizesSlotsToTheirShape() throws {
        let paths = tempPaths()
        let json = #"[{"groupId":"g1","shape":{"rows":3,"cols":3},"pages":[{"slots":[]}]}]"#
        try Data(json.utf8).write(to: paths.fileURL)
        XCTAssertEqual(BinderLayoutsModel(paths: paths).layout(for: "g1")?.pages.first?.slots.count, 9)
    }

    func testAFailedWriteRollsBackAndReportsRatherThanLying() {
        // A directory where a file should be: the write throws, the model must not keep the change.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binders-\(UUID().uuidString).json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = BinderLayoutsModel(paths: BinderPaths(fileURL: dir))
        var reported: String?
        model.onWriteError = { reported = $0 }
        model.save(sample("g1"))
        XCTAssertNil(model.layout(for: "g1"), "an unwritable change must not survive in memory")
        XCTAssertNotNil(reported)
    }
}
