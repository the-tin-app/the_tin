import XCTest
@testable import TheTin

@MainActor
final class BinderLayoutsModelTests: XCTestCase {
    private func tempPaths() -> BinderPaths {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binders-\(UUID().uuidString).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("corrupt"))
        }
        return BinderPaths(fileURL: url)
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

    /// `Dictionary(uniqueKeysWithValues:)` TRAPS on a duplicate key, which would crash the app at
    /// every launch until someone deleted the file by hand.
    func testADuplicateGroupIdDoesNotCrashTheApp() throws {
        let paths = tempPaths()
        let json = """
        [{"groupId":"g1","shape":{"rows":1,"cols":1},"pages":[{"slots":[{"cardId":"a"}]}]},\
        {"groupId":"g1","shape":{"rows":1,"cols":1},"pages":[{"slots":[{"cardId":"b"}]}]}]
        """
        try Data(json.utf8).write(to: paths.fileURL)
        let model = BinderLayoutsModel(paths: paths)
        XCTAssertEqual(model.layouts.count, 1)
        XCTAssertEqual(model.layout(for: "g1")?.pages.first?.slots.first??.cardId, "b",
                       "last writer wins")
    }

    /// The wants.json lesson: one unreadable record must not take its siblings with it.
    func testOneUnreadableLayoutIsDroppedAloneAndTheRestSurvive() throws {
        let paths = tempPaths()
        let json = """
        [{"groupId":"g1","shape":{"rows":1,"cols":1},"pages":[{"slots":[{"cardId":"a"}]}]},\
        {"nonsense":true},\
        {"groupId":"g3","shape":{"rows":1,"cols":1},"pages":[{"slots":[{"cardId":"c"}]}]}]
        """
        try Data(json.utf8).write(to: paths.fileURL)
        XCTAssertEqual(Set(BinderLayoutsModel(paths: paths).layouts.keys), ["g1", "g3"])
    }

    /// A file we could not read AT ALL is preserved, not written over.
    func testAnUnreadableFileIsMovedAsideRatherThanOverwritten() throws {
        let paths = tempPaths()
        try Data("this is not json".utf8).write(to: paths.fileURL)
        let model = BinderLayoutsModel(paths: paths)
        XCTAssertTrue(model.layouts.isEmpty)
        model.save(sample("g1"))
        let sidecar = paths.fileURL.appendingPathExtension("corrupt")
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "this is not json")
        XCTAssertEqual(BinderLayoutsModel(paths: paths).layout(for: "g1"), sample("g1"))
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
