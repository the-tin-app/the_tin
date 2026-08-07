import XCTest
@testable import TheTin

/// The virtual binder's arithmetic: how many photographs, what each one frames, and which pocket a
/// detected card lands in. Pure — no camera, no Vision, no catalog.
final class BinderPlanTests: XCTestCase {

    // MARK: - Shape

    func testShapeClampsToTheSupportedRange() {
        XCTAssertEqual(BinderShape(rows: 1, cols: 9), BinderShape(rows: 2, cols: 5))
        XCTAssertEqual(BinderShape(rows: 3, cols: 3).pocketsPerPage, 9)
    }

    // MARK: - Tiling (§5.2's table, verbatim)

    func testTileCountsAndOverlapMatchTheSpecTable() {
        // Binder | tiles/axis | shots per page | overlap
        XCTAssertEqual(BinderPlan.offsets(2), [0])           // 2×2 → 1 shot, no overlap
        XCTAssertEqual(BinderPlan.offsets(3), [0, 1])        // 3×3 → 4 shots, middle seen twice
        XCTAssertEqual(BinderPlan.offsets(4), [0, 2])        // 4×4 → 4 shots, no overlap
        XCTAssertEqual(BinderPlan.offsets(5), [0, 2, 3])     // 5×5 → 9 shots, one row+col twice
    }

    func testShotsPerPage() {
        for (shape, shots) in [(BinderShape(rows: 2, cols: 2), 1), (BinderShape(rows: 3, cols: 3), 4),
                               (BinderShape(rows: 4, cols: 4), 4), (BinderShape(rows: 5, cols: 5), 9)] {
            XCTAssertEqual(BinderPlan.tiles(shape: shape, page: 0).count, shots, "\(shape)")
        }
    }

    /// The last tile is shifted BACK, never allowed to hang off the page — otherwise a 3-wide
    /// binder's second tile would frame columns 2–3 of a 3-column page and half the shot would be
    /// the table.
    func testEveryTileWindowStaysInsideThePage() {
        for rows in BinderShape.range {
            for cols in BinderShape.range {
                let shape = BinderShape(rows: rows, cols: cols)
                for tile in BinderPlan.tiles(shape: shape, page: 0) {
                    XCTAssertLessThanOrEqual(tile.rowOffset + BinderPlan.tileSide, shape.rows)
                    XCTAssertLessThanOrEqual(tile.colOffset + BinderPlan.tileSide, shape.cols)
                }
            }
        }
    }

    func testEveryPocketIsCoveredByAtLeastOneTile() {
        for rows in BinderShape.range {
            for cols in BinderShape.range {
                let shape = BinderShape(rows: rows, cols: cols)
                var covered = Set<BinderSlot>()
                for tile in BinderPlan.tiles(shape: shape, page: 0) {
                    for dr in 0..<BinderPlan.tileSide {
                        for dc in 0..<BinderPlan.tileSide {
                            covered.insert(BinderSlot(page: 0, row: tile.rowOffset + dr,
                                                      col: tile.colOffset + dc))
                        }
                    }
                }
                XCTAssertEqual(covered.count, shape.pocketsPerPage, "\(rows)×\(cols)")
            }
        }
    }

    // MARK: - Naming

    func testTileNamesSkipAnAxisWithNothingToDisambiguate() {
        let square = BinderShape(rows: 2, cols: 2)
        XCTAssertEqual(BinderPlan.name(BinderPlan.tiles(shape: square, page: 0)[0], shape: square),
                       "the whole page")

        let threeByThree = BinderShape(rows: 3, cols: 3)
        XCTAssertEqual(BinderPlan.tiles(shape: threeByThree, page: 0)
                        .map { BinderPlan.name($0, shape: threeByThree) },
                       ["top-left", "top-right", "bottom-left", "bottom-right"])

        // A 2-row × 5-col binder has one tile down and three across: no "top", but a middle.
        let wide = BinderShape(rows: 2, cols: 5)
        XCTAssertEqual(BinderPlan.tiles(shape: wide, page: 0).map { BinderPlan.name($0, shape: wide) },
                       ["left", "middle", "right"])
    }

    // MARK: - Slot assignment

    func testCentreQuantizesToTheTilesTwoByTwoSubGrid() {
        let tile = BinderTile(page: 1, rowOffset: 1, colOffset: 1)   // 3×3's bottom-right tile
        let corners: [(CGPoint, Int, Int)] = [
            (CGPoint(x: 0.25, y: 0.25), 1, 1),
            (CGPoint(x: 0.75, y: 0.25), 1, 2),
            (CGPoint(x: 0.25, y: 0.75), 2, 1),
            (CGPoint(x: 0.75, y: 0.75), 2, 2),
        ]
        for (centre, row, col) in corners {
            XCTAssertEqual(BinderPlan.slot(centre: centre, in: tile),
                           BinderSlot(page: 1, row: row, col: col), "\(centre)")
        }
    }

    func testBestObservationWinsAPocket() {
        let shape = BinderShape(rows: 3, cols: 3)
        let slot = BinderSlot(page: 0, row: 0, col: 0)
        let out = BinderPlan.assign([(slot, 22, 650, "weak"), (slot, 71, 650, "strong")], shape: shape)
        XCTAssertEqual(out[slot], "strong")
    }

    /// The overlap between tiles is the point: a pocket photographed twice votes, it doesn't
    /// conflict. Same pocket reached from two different tiles, best inliers wins.
    func testOverlappingTilesVoteOnTheSharedPocket() {
        let shape = BinderShape(rows: 3, cols: 3)
        let shared = CGPoint(x: 0.75, y: 0.75)      // bottom-right of the top-left tile…
        let alsoShared = CGPoint(x: 0.25, y: 0.25)  // …is top-left of the bottom-right tile
        let a = BinderPlan.slot(centre: shared, in: BinderTile(page: 0, rowOffset: 0, colOffset: 0))
        let b = BinderPlan.slot(centre: alsoShared, in: BinderTile(page: 0, rowOffset: 1, colOffset: 1))
        XCTAssertEqual(a, b, "3×3's centre pocket is seen by both diagonal tiles")

        let out = BinderPlan.assign([(a, 30, 650, "first look"), (b, 64, 650, "better look")],
                                    shape: shape)
        XCTAssertEqual(out[a], "better look")
    }

    func testPhantomsAreDroppedOnKeypointCount() {
        let shape = BinderShape(rows: 3, cols: 3)
        let slot = BinderSlot(page: 0, row: 0, col: 0)
        // A phantom sits at a median fpCount of 15 against a real card's 650. Even with a higher
        // inlier count it must never take a pocket.
        let out = BinderPlan.assign([(slot, 99, 15, "phantom"), (slot, 21, 650, "card")], shape: shape)
        XCTAssertEqual(out[slot], "card")
        XCTAssertTrue(BinderPlan.assign([(slot, 99, 15, "phantom")], shape: shape).isEmpty)
    }

    /// A wider-than-2×2 frame quantizes margin junk onto a pocket, but a shifted-back tile can also
    /// produce an out-of-page slot if the caller mis-computes the offset. Both are refused here
    /// rather than trusted upstream.
    func testSlotsOutsideThePageAreRefused() {
        let shape = BinderShape(rows: 3, cols: 3)
        let outside = [BinderSlot(page: 0, row: 3, col: 0), BinderSlot(page: 0, row: 0, col: 3),
                       BinderSlot(page: 0, row: -1, col: 0)]
        XCTAssertTrue(BinderPlan.assign(outside.map { ($0, 50, 650, "x") }, shape: shape).isEmpty)
    }

    func testAtMostOneCardPerPocket() {
        let shape = BinderShape(rows: 2, cols: 2)
        // Nine detections over a four-pocket window — the measured phantom rate.
        let obs = (0..<9).map { i -> (BinderSlot, Int, Int, String) in
            (BinderSlot(page: 0, row: i % 2, col: (i / 2) % 2), 20 + i, 650, "obs\(i)")
        }
        XCTAssertLessThanOrEqual(BinderPlan.assign(obs, shape: shape).count, shape.pocketsPerPage)
    }
}
