import UIKit
import XCTest
@testable import TheTin

/// Plain-FileManager BackupStore over a temp dir — the same double BackupServiceTests uses,
/// duplicated rather than shared because it is four lines and `private` to that file.
private struct TempDirStore: BackupStore {
    let dir: URL
    func containerURL() -> URL? { dir }
    func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    func rotate(_ url: URL, to prev: URL) {}
    func requestDownload(_ url: URL) {}
}

/// A store with iCloud off — every mirror call must be a silent no-op.
private struct NoContainerStore: BackupStore {
    func containerURL() -> URL? { nil }
    func read(_ url: URL) throws -> Data { throw CocoaError(.fileNoSuchFile) }
    func write(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteUnknown) }
    func rotate(_ url: URL, to prev: URL) {}
    func requestDownload(_ url: URL) {}
}

final class PhotoStoreMirrorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var container: URL { dir.appendingPathComponent("icloud", isDirectory: true) }
    private func makeStore(local: String, mirror: BackupStore?) -> PhotoStore {
        PhotoStore(root: dir.appendingPathComponent(local, isDirectory: true), mirror: mirror)
    }

    private func solid() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60), format: format)
            .image { ctx in
                UIColor.blue.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
            }
    }

    func testMirrorUpCopiesThePhotoIntoTheContainer() throws {
        let store = makeStore(local: "a", mirror: TempDirStore(dir: container))
        let file = try store.save(solid(), entryId: "e1")

        store.mirrorUp(entryId: "e1", file: file)

        let remote = container.appendingPathComponent("photos/e1/\(file)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.path))
    }

    func testMirrorUpWithoutICloudIsASilentNoOp() throws {
        let store = makeStore(local: "a", mirror: NoContainerStore())
        let file = try store.save(solid(), entryId: "e1")
        store.mirrorUp(entryId: "e1", file: file)   // must not throw or trap
        XCTAssertNotNil(store.image(entryId: "e1", file: file))
    }

    /// The restore path: a second device holds the snapshot's entries but none of the files.
    func testMirrorDownPullsPhotosOntoADeviceThatHasNone() throws {
        let uploader = makeStore(local: "a", mirror: TempDirStore(dir: container))
        let file = try uploader.save(solid(), entryId: "e1")
        uploader.mirrorUp(entryId: "e1", file: file)

        let restorer = makeStore(local: "b", mirror: TempDirStore(dir: container))
        XCTAssertNil(restorer.image(entryId: "e1", file: file))

        restorer.mirrorDown()

        XCTAssertNotNil(restorer.image(entryId: "e1", file: file))
    }

    /// Re-running must not clobber a local file — mirrorDown is called on every restore.
    func testMirrorDownLeavesAnExistingLocalFileAlone() throws {
        let uploader = makeStore(local: "a", mirror: TempDirStore(dir: container))
        let file = try uploader.save(solid(), entryId: "e1")
        uploader.mirrorUp(entryId: "e1", file: file)

        let local = uploader.url(entryId: "e1", file: file)
        try Data("local-wins".utf8).write(to: local, options: .atomic)

        uploader.mirrorDown()

        XCTAssertEqual(try Data(contentsOf: local), Data("local-wins".utf8))
    }

    func testMirrorDownWithNothingMirroredDoesNothing() {
        makeStore(local: "a", mirror: TempDirStore(dir: container)).mirrorDown()
    }
}
