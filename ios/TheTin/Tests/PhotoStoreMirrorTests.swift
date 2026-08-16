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

    private func entry(_ id: String) -> CollectionEntry {
        CollectionEntry(id: id, cardId: "c-\(id)", groupId: "", qty: 1, condition: "NM",
                        grade: nil, pricePaid: nil, acquiredAt: nil, acquiredFrom: nil,
                        addedAt: Date())
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

    /// The centring picture has to ride the same mirror as every other photo, or a restored
    /// device shows a ratio with nothing behind it and no way to check it again. `needed` is what
    /// drives the pull, so a slot missing from it is a slot that never restores.
    func testTheCentringPictureIsMirroredLikeAnyOtherPhoto() {
        var entry = CollectionEntry(id: "e1", cardId: "swsh7-215", groupId: "", qty: 1,
                                    condition: nil, grade: nil, pricePaid: nil, acquiredAt: nil,
                                    acquiredFrom: nil, addedAt: Date())
        entry.photos = EntryPhotos(front: "f.jpg", centering: "c.jpg")

        let needed = PhotoStore.needed(from: [entry])
        XCTAssertEqual(needed["e1"]?.sorted(), ["c.jpg", "f.jpg"],
                       "the centring picture must be pulled on restore like any other photo")
    }

    /// A measured copy is its own acquisition: folding it into a x2 would attach one card's
    /// borders to another card nobody measured.
    func testAMeasuredCopyDoesNotFoldIntoAQuantity() {
        var measured = CollectionEntry(id: "e1", cardId: "swsh7-215", groupId: "", qty: 1,
                                       condition: nil, grade: nil, pricePaid: nil, acquiredAt: nil,
                                       acquiredFrom: nil, addedAt: Date())
        XCTAssertFalse(measured.hasAcquisitionDetail, "precondition: nothing per-copy yet")
        measured.centering = Centering(left: 40, right: 20, top: 30, bottom: 60)
        XCTAssertTrue(measured.hasAcquisitionDetail)
    }

    /// The measurement lives on the entry, and the entry IS the backup snapshot — so this is the
    /// whole of "centring is backed up". A decode that drops it would lose it silently.
    func testCentringSurvivesTheBackupEncodeDecode() throws {
        var entry = CollectionEntry(id: "e1", cardId: "swsh7-215", groupId: "", qty: 1,
                                    condition: nil, grade: nil, pricePaid: nil, acquiredAt: nil,
                                    acquiredFrom: nil, addedAt: Date())
        entry.centering = Centering(outerLeft: 10, innerLeft: 65, outerRight: 5, innerRight: 50,
                                    outerTop: 8, innerTop: 61, outerBottom: 3, innerBottom: 50)
        entry.photos = EntryPhotos(centering: "c.jpg")

        let round = try JSONDecoder().decode(CollectionEntry.self,
                                             from: try JSONEncoder().encode(entry))
        XCTAssertEqual(round.centering, entry.centering)
        XCTAssertEqual(round.photos?.centering, "c.jpg")
        // The eight lines survive, not just the ratio: reopening the editor has to put them back
        // where they were left, or "adjust" means "start again".
        XCTAssertEqual(round.centering?.outerLeft, 10)
        XCTAssertEqual(round.centering?.innerLeft, 65)
    }

    /// A collection.json written before centring existed must still decode — the same rule every
    /// optional field on this type follows.
    func testAnEntryWrittenBeforeCentringExistedStillDecodes() throws {
        let legacy = """
        {"id":"e1","cardId":"swsh7-215","groupId":"","qty":1,"addedAt":0}
        """
        let entry = try JSONDecoder().decode(CollectionEntry.self, from: Data(legacy.utf8))
        XCTAssertNil(entry.centering)
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

        restorer.mirrorDown(needed: ["e1": [file]])

        XCTAssertNotNil(restorer.image(entryId: "e1", file: file))
    }

    /// The bug this whole path was rewritten for: the file is not in iCloud yet when the restore
    /// runs, and a later pass has to get it. The old listing-based pull had no later pass, so a
    /// photo still in flight at restore time was lost for good (iPad, 2026-08-10).
    func testMirrorDownRetriesAFileThatArrivesLater() throws {
        let uploader = makeStore(local: "a", mirror: TempDirStore(dir: container))
        let file = try uploader.save(solid(), entryId: "e1")

        // Restore happens first; nothing has been mirrored up yet.
        let restorer = makeStore(local: "b", mirror: TempDirStore(dir: container))
        restorer.mirrorDown(needed: ["e1": [file]])
        XCTAssertNil(restorer.image(entryId: "e1", file: file))

        uploader.mirrorUp(entryId: "e1", file: file)   // arrives afterwards
        restorer.mirrorDown(needed: ["e1": [file]])    // the next launch's pass

        XCTAssertNotNil(restorer.image(entryId: "e1", file: file))
    }

    /// Only what the entries name. A file left in the container by a deleted entry must not be
    /// resurrected onto the device.
    func testMirrorDownIgnoresAContainerFileNoEntryReferences() throws {
        let uploader = makeStore(local: "a", mirror: TempDirStore(dir: container))
        let orphan = try uploader.save(solid(), entryId: "gone")
        uploader.mirrorUp(entryId: "gone", file: orphan)

        let restorer = makeStore(local: "b", mirror: TempDirStore(dir: container))
        restorer.mirrorDown(needed: [:])

        XCTAssertNil(restorer.image(entryId: "gone", file: orphan))
    }

    /// Re-running must not clobber a local file — mirrorDown runs on every restore AND launch.
    func testMirrorDownLeavesAnExistingLocalFileAlone() throws {
        let uploader = makeStore(local: "a", mirror: TempDirStore(dir: container))
        let file = try uploader.save(solid(), entryId: "e1")
        uploader.mirrorUp(entryId: "e1", file: file)

        let local = uploader.url(entryId: "e1", file: file)
        try Data("local-wins".utf8).write(to: local, options: .atomic)

        uploader.mirrorDown(needed: ["e1": [file]])

        XCTAssertEqual(try Data(contentsOf: local), Data("local-wins".utf8))
    }

    func testMirrorDownWithNothingMirroredDoesNothing() {
        makeStore(local: "a", mirror: TempDirStore(dir: container))
            .mirrorDown(needed: ["e1": ["nope.jpg"]])
    }

    func testNeededSkipsEntriesWithoutPhotos() {
        var withPhotos = entry("e1")
        withPhotos.photos = EntryPhotos(front: "f.jpg", back: nil, details: ["d.jpg"])
        let without = entry("e2")

        let needed = PhotoStore.needed(from: [withPhotos, without])

        XCTAssertEqual(needed, ["e1": ["f.jpg", "d.jpg"]])
    }
}
