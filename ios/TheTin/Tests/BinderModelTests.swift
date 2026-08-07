import CoreImage
import XCTest
@testable import TheTin

/// The session: capture progress, slot assignment, corrections, and what survives the screen. No
/// camera, no matcher, no catalog — `BinderModel` is built so the whole capture-to-pocket path can be
/// driven by hand.
@MainActor
final class BinderModelTests: XCTestCase {

    private var root: URL!
    private var cache: BinderCache!
    /// The real thing's shape: a 4032×3024 still off the phone.
    private let extent = CGRect(x: 0, y: 0, width: 4032, height: 3024)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("binder-model-\(UUID().uuidString)")
        cache = BinderCache(root: root)
        // ⚠️ Reset in setUp AND tearDown. `binderShape` is persisted, so a test that leaves it set
        // fails a DIFFERENT test on the next run — the trap `ScanModelTests` documents.
        AppConfig.binderShape = .default
    }

    override func tearDownWithError() throws {
        AppConfig.binderShape = .default
        try? FileManager.default.removeItem(at: root)
        root = nil; cache = nil
    }

    private func model(_ shape: BinderShape = .default) -> BinderModel {
        BinderModel.forTesting(shape: shape, cache: cache)
    }

    private func photo() -> CIImage { CIImage(color: .gray).cropped(to: extent) }

    /// A card-shaped quad centred at `centre`, given in coordinates normalized to the photograph with
    /// a **top-left** origin — i.e. how a person describes "the top-right card". Vision's own space is
    /// bottom-left, so the y flip here mirrors `CardQuad.normalizedRect`'s and is what makes this
    /// helper an independent check on it rather than a restatement.
    private func cell(at centre: CGPoint, cardId: String? = nil, options: [String] = [],
                     inliers: Int = 40, fpCount: Int = 650) -> LensCell {
        let w = 0.30 * extent.width, h = 0.42 * extent.height
        let cx = centre.x * extent.width, cy = (1 - centre.y) * extent.height
        let quad = CardQuad(topLeft: CGPoint(x: cx - w / 2, y: cy + h / 2),
                            topRight: CGPoint(x: cx + w / 2, y: cy + h / 2),
                            bottomLeft: CGPoint(x: cx - w / 2, y: cy - h / 2),
                            bottomRight: CGPoint(x: cx + w / 2, y: cy - h / 2))
        let state: LensCellState = cardId.map { .identified(cardId: $0, inliers: inliers) }
            ?? (options.isEmpty ? .noMatch : .ambiguous(options))
        return LensCell(quad: quad, fpCount: fpCount, state: state)
    }

    // MARK: - Progress through a page

    func testAThreeByThreeBinderAsksForFourPhotographsPerPage() throws {
        let m = model()
        XCTAssertEqual(m.tiles.count, 4)
        XCTAssertEqual(m.progressText, "Photo 1 of 4 · page 1")

        for expected in ["top-left", "top-right", "bottom-left", "bottom-right"] {
            XCTAssertEqual(m.currentTileName, expected)
            m.accept(photo(), for: try XCTUnwrap(m.currentTile))
        }
        XCTAssertTrue(m.isPageComplete)
        XCTAssertNil(m.currentTile)
    }

    func testRetakeStepsBackOneAndNeverPastTheStart() throws {
        let m = model()
        m.accept(photo(), for: try XCTUnwrap(m.currentTile))
        XCTAssertEqual(m.tileIndex, 1)
        m.retakePrevious()
        XCTAssertEqual(m.tileIndex, 0)
        m.retakePrevious()
        XCTAssertEqual(m.tileIndex, 0, "there is nothing before the first photo")
    }

    func testNextPageStartsOverAndCountsThePageJustFinished() throws {
        let m = model()
        for _ in m.tiles { m.accept(photo(), for: try XCTUnwrap(m.currentTile)) }
        m.nextPage()
        XCTAssertEqual(m.page, 1)
        XCTAssertEqual(m.tileIndex, 0)
        XCTAssertEqual(m.progressText, "Photo 1 of 4 · page 2")
        XCTAssertEqual(m.pageCount, 1, "page 2 has no photograph yet — it is not a page of the binder")
    }

    /// ⚠️ The silent one. "Shoot half of page 2, then tap Finish" is an ordinary thing to do, and a
    /// page counter maintained by the navigation buttons was one short — putting those cards in the
    /// list and the scan, and on no page the user could flip to.
    func testAPartlyShotPageIsStillReachable() throws {
        let m = model()
        for _ in m.tiles { m.accept(photo(), for: try XCTUnwrap(m.currentTile)) }
        m.nextPage()
        let tile = try XCTUnwrap(m.currentTile)
        m.accept(photo(), for: tile)
        m.assignSlots(cells: [cell(at: CGPoint(x: 0.25, y: 0.25), cardId: "on page two")],
                      tile: tile, extent: extent)
        m.finish()
        XCTAssertEqual(m.pageCount, 2)
        XCTAssertEqual(m.entry(BinderSlot(page: 1, row: 0, col: 0))?.cardId, "on page two")
    }

    /// ⚠️ Browsing must not hold 24.5 MP source photographs. Each is an order of magnitude bigger than
    /// anything else on this screen, the tile JPEGs on disk replace them, and jetsam leaves no report.
    func testFinishingDropsTheSourcePhotographs() throws {
        let m = model()
        m.accept(photo(), for: try XCTUnwrap(m.currentTile))
        XCTAssertFalse(m.images.isEmpty)
        m.finish()
        XCTAssertTrue(m.images.isEmpty)
        XCTAssertEqual(m.phase, .browsing)
    }

    // MARK: - Detections → pockets

    /// The whole point of asking the shape up front: four cards in a photograph land in the four
    /// pockets that photograph frames, and which pockets those are is arithmetic.
    func testFourCardsLandInTheTilesFourPockets() throws {
        let m = model()
        let tile = try XCTUnwrap(m.currentTile)          // 3×3's top-left: pockets (0,0)…(1,1)
        m.assignSlots(cells: [cell(at: CGPoint(x: 0.25, y: 0.25), cardId: "tl"),
                              cell(at: CGPoint(x: 0.75, y: 0.25), cardId: "tr"),
                              cell(at: CGPoint(x: 0.25, y: 0.75), cardId: "bl"),
                              cell(at: CGPoint(x: 0.75, y: 0.75), cardId: "br")],
                      tile: tile, extent: extent)
        XCTAssertEqual(m.entry(BinderSlot(page: 0, row: 0, col: 0))?.cardId, "tl")
        XCTAssertEqual(m.entry(BinderSlot(page: 0, row: 0, col: 1))?.cardId, "tr")
        XCTAssertEqual(m.entry(BinderSlot(page: 0, row: 1, col: 0))?.cardId, "bl")
        XCTAssertEqual(m.entry(BinderSlot(page: 0, row: 1, col: 1))?.cardId, "br")
    }

    /// The bottom-right tile of a 3×3 page frames pockets (1,1)…(2,2), so its top-left card is the
    /// page's CENTRE pocket — the one photographed twice. Getting this offset wrong would put a whole
    /// page's cards one row and one column out, which the grid would render without complaint.
    func testATilesOffsetIsAppliedToThePageCoordinates() throws {
        let m = model()
        let bottomRight = BinderTile(page: 0, rowOffset: 1, colOffset: 1)
        m.assignSlots(cells: [cell(at: CGPoint(x: 0.25, y: 0.25), cardId: "centre"),
                              cell(at: CGPoint(x: 0.75, y: 0.75), cardId: "corner")],
                      tile: bottomRight, extent: extent)
        XCTAssertEqual(m.entry(BinderSlot(page: 0, row: 1, col: 1))?.cardId, "centre")
        XCTAssertEqual(m.entry(BinderSlot(page: 0, row: 2, col: 2))?.cardId, "corner")
    }

    /// ~49% of quads over a binder page are phantoms — glare bands, empty pockets, page edges — at a
    /// median 15 keypoints against a real card's 650. They must not take a pocket, and a pocket they
    /// were the only candidate for must read as EMPTY rather than as a card we couldn't name.
    func testPhantomsNeverTakeAPocket() throws {
        let m = model()
        let tile = try XCTUnwrap(m.currentTile)
        m.assignSlots(cells: [cell(at: CGPoint(x: 0.25, y: 0.25), inliers: 99, fpCount: 15),
                              cell(at: CGPoint(x: 0.75, y: 0.25), cardId: "real", fpCount: 650)],
                      tile: tile, extent: extent)
        XCTAssertNil(m.entry(BinderSlot(page: 0, row: 0, col: 0)))
        XCTAssertEqual(m.entry(BinderSlot(page: 0, row: 0, col: 1))?.cardId, "real")
    }

    /// An unresolved pocket keeps its four candidates, so tap-to-resolve works minutes later without
    /// holding a plate or re-running the match.
    func testAnAmbiguousCellKeepsItsChooserOptions() throws {
        let m = model()
        let tile = try XCTUnwrap(m.currentTile)
        m.assignSlots(cells: [cell(at: CGPoint(x: 0.25, y: 0.25), options: ["a", "b", "c", "d"])],
                      tile: tile, extent: extent)
        let entry = try XCTUnwrap(m.entry(BinderSlot(page: 0, row: 0, col: 0)))
        XCTAssertNil(entry.cardId)
        XCTAssertEqual(entry.options, ["a", "b", "c", "d"])
        XCTAssertEqual(m.unresolvedCount, 1)
        XCTAssertEqual(m.resolvedCount, 0)
    }

    /// The 3×3 overlap, end to end: the centre pocket is framed by all four tiles, and a resolved look
    /// beats an unresolved one. This is the "overlap is an asset" claim actually being cashed.
    func testAResolvedSecondLookWinsTheSharedCentrePocket() throws {
        let m = model()
        let centre = BinderSlot(page: 0, row: 1, col: 1)
        m.assignSlots(cells: [cell(at: CGPoint(x: 0.75, y: 0.75), options: ["a", "b"])],
                      tile: BinderTile(page: 0, rowOffset: 0, colOffset: 0), extent: extent)
        XCTAssertNil(m.entry(centre)?.cardId)
        m.assignSlots(cells: [cell(at: CGPoint(x: 0.25, y: 0.25), cardId: "found", inliers: 55)],
                      tile: BinderTile(page: 0, rowOffset: 1, colOffset: 1), extent: extent)
        XCTAssertEqual(m.entry(centre)?.cardId, "found")
    }

    // MARK: - Corrections

    func testAPickWinsAndIsRemembered() throws {
        let m = model()
        let slot = BinderSlot(page: 0, row: 1, col: 2)
        m.pick("sv1-25", for: slot)
        let entry = try XCTUnwrap(m.entry(slot))
        XCTAssertEqual(entry.cardId, "sv1-25")
        XCTAssertTrue(entry.byHand)
        XCTAssertTrue(entry.options.isEmpty,
                      "picking answers the question — the chooser should not still be offered")
    }

    func testClearingAPocketMakesItEmptyAgain() {
        let m = model()
        let slot = BinderSlot(page: 0, row: 0, col: 0)
        m.pick("sv1-25", for: slot)
        m.clearSlot(slot)
        XCTAssertNil(m.entry(slot))
    }

    /// A re-shot tile drops its own machine answers — a card pulled from a pocket between shots must
    /// not linger — but never the user's corrections.
    func testReShootingATileKeepsCorrectionsAndDropsMachineAnswers() throws {
        let m = model()
        let tile = try XCTUnwrap(m.currentTile)
        let corrected = BinderSlot(page: 0, row: 0, col: 0)
        let machine = BinderSlot(page: 0, row: 0, col: 1)
        m.assignSlots(cells: [cell(at: CGPoint(x: 0.25, y: 0.25), cardId: "wrong"),
                              cell(at: CGPoint(x: 0.75, y: 0.25), cardId: "auto")],
                      tile: tile, extent: extent)
        m.pick("hand-picked", for: corrected)

        m.accept(photo(), for: tile)
        XCTAssertEqual(m.entry(corrected)?.cardId, "hand-picked")
        XCTAssertNil(m.entry(machine), "a re-shot tile's machine answers go")
    }

    // MARK: - Surviving the screen

    func testAScanReopensWhereItWasLeft() {
        let m = model(BinderShape(rows: 4, cols: 4))
        m.pick("sv1-25", for: BinderSlot(page: 0, row: 2, col: 3))
        m.finish()

        let reopened = BinderModel(cache: cache)
        XCTAssertEqual(reopened.phase, .browsing, "a saved binder opens on the binder, not on setup")
        XCTAssertEqual(reopened.shape, BinderShape(rows: 4, cols: 4))
        XCTAssertEqual(reopened.entry(BinderSlot(page: 0, row: 2, col: 3))?.cardId, "sv1-25")
    }

    func testAScanFromYesterdayIsGoneAndTheSessionStartsAtSetup() {
        let m = model()
        m.pick("sv1-25", for: BinderSlot(page: 0, row: 0, col: 0))
        m.finish()
        let tomorrow = BinderModel(cache: cache, now: Date().addingTimeInterval(25 * 3600))
        XCTAssertEqual(tomorrow.phase, .setup)
        XCTAssertTrue(tomorrow.scan.entries.isEmpty)
    }

    func testResetClearsTheCacheAndReturnsToSetup() {
        let m = model()
        m.pick("sv1-25", for: BinderSlot(page: 0, row: 0, col: 0))
        m.reset()
        XCTAssertEqual(m.phase, .setup)
        XCTAssertNil(cache.load())
    }

    /// The shape is remembered because which binder you own is a property of you, not of one scan —
    /// and setup is the only thing between the user and the camera, so it should already be right.
    func testTheShapeIsRememberedForNextTime() {
        _ = model(BinderShape(rows: 5, cols: 5))
        XCTAssertEqual(AppConfig.binderShape, BinderShape(rows: 5, cols: 5))
        cache.clear()
        XCTAssertEqual(BinderModel(cache: cache).shape, BinderShape(rows: 5, cols: 5))
    }
}
