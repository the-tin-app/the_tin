import UIKit
import XCTest
@testable import TheTin

final class PhotoStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var store: PhotoStore { PhotoStore(root: root) }

    /// A solid-colour image at an exact PIXEL size (scale 1), so size assertions mean pixels.
    private func solid(_ width: CGFloat, _ height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .image { ctx in
                UIColor.red.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
    }

    func testDownscaleClampsTheLongestSideAndKeepsAspect() {
        let out = PhotoStore.downscaled(solid(4000, 3000))
        XCTAssertEqual(out.scale, 1, "a 3x renderer scale would make this 4800px, not 1600px")
        XCTAssertEqual(out.size.width, 1600)
        XCTAssertEqual(out.size.height, 1200)
    }

    func testDownscaleClampsThePortraitLongestSideToo() {
        let out = PhotoStore.downscaled(solid(3000, 4000))
        XCTAssertEqual(out.size.height, 1600)
        XCTAssertEqual(out.size.width, 1200)
    }

    /// Re-encoding an already-small photo would only lose quality.
    func testDownscaleLeavesASmallImageAlone() {
        let input = solid(900, 600)
        let out = PhotoStore.downscaled(input)
        XCTAssertEqual(out.size, input.size)
    }

    func testSaveWritesAJPEGAndReturnsItsFilename() throws {
        let name = try store.save(solid(4000, 3000), entryId: "entry-1")
        XCTAssertTrue(name.hasSuffix(".jpg"))
        let url = store.url(entryId: "entry-1", file: name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let round = try XCTUnwrap(store.image(entryId: "entry-1", file: name))
        XCTAssertEqual(round.size.width * round.scale, 1600)
    }

    func testTwoSavesForOneEntryBothSurvive() throws {
        let a = try store.save(solid(100, 100), entryId: "entry-1")
        let b = try store.save(solid(100, 100), entryId: "entry-1")
        XCTAssertNotEqual(a, b)
        XCTAssertNotNil(store.image(entryId: "entry-1", file: a))
        XCTAssertNotNil(store.image(entryId: "entry-1", file: b))
    }

    func testImageIsNilForAMissingFile() {
        XCTAssertNil(store.image(entryId: "nobody", file: "nothing.jpg"))
    }

    func testPruneRemovesOnlyUnreferencedDirectories() throws {
        let keptFile = try store.save(solid(100, 100), entryId: "keep")
        _ = try store.save(solid(100, 100), entryId: "drop")

        store.prune(keeping: ["keep"])

        XCTAssertNotNil(store.image(entryId: "keep", file: keptFile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: "drop").path))
    }

    /// The root may not exist yet on a device that has never taken a photo.
    func testPruneOnAnAbsentRootDoesNothing() {
        let absent = PhotoStore(root: root.appendingPathComponent("never-created"))
        absent.prune(keeping: [])   // must not throw or trap
    }
}
