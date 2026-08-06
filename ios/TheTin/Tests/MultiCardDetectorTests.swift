import CoreImage
import XCTest
@testable import TheTin

final class MultiCardDetectorTests: XCTestCase {

    /// A synthetic "binder page": nine light card-shaped rectangles on a dark ground. Vision's
    /// rectangles request finds high-contrast quads reliably, which is all this asserts — matching
    /// accuracy is Task 3's problem and real-photo accuracy is Task 8's.
    private func syntheticPage(rows: Int, cols: Int) -> CIImage {
        let cardW: CGFloat = 330, cardH: CGFloat = 460, gap: CGFloat = 40
        let w = CGFloat(cols) * (cardW + gap) + gap
        let h = CGFloat(rows) * (cardH + gap) + gap
        var image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        for r in 0..<rows { for c in 0..<cols {
            let rect = CGRect(x: gap + CGFloat(c) * (cardW + gap),
                              y: gap + CGFloat(r) * (cardH + gap),
                              width: cardW, height: cardH)
            let card = CIImage(color: .white).cropped(to: rect)
            image = card.composited(over: image)
        } }
        return image
    }

    func testFindsEveryCardOnASyntheticPage() throws {
        let ci = syntheticPage(rows: 3, cols: 3)
        let cells = MultiCardDetector.cells(in: ci, context: CIContext())
        XCTAssertGreaterThanOrEqual(cells.count, 8, "expected ~9 pockets, got \(cells.count)")
        XCTAssertLessThanOrEqual(cells.count, 9, "duplicates were not merged")
    }

    func testEveryCellIsACanonicalPlate() throws {
        let cells = MultiCardDetector.cells(in: syntheticPage(rows: 1, cols: 2), context: CIContext())
        let cell = try XCTUnwrap(cells.first)
        XCTAssertEqual(cell.plate.width, Int(kFPCanonW))
        XCTAssertEqual(cell.plate.height, Int(kFPCanonH))
        XCTAssertEqual(cell.plate.pixels.count, cell.plate.bytesPerRow * cell.plate.height)
    }

    func testCellsCarryTheirQuadSoTheyCanBeDrawnOnThePhoto() throws {
        let cells = MultiCardDetector.cells(in: syntheticPage(rows: 1, cols: 2), context: CIContext())
        XCTAssertEqual(cells.count, 2)
        let centers = cells.map { ScoredQuad(quad: $0.quad, confidence: 0).center.x }
        XCTAssertNotEqual(centers[0], centers[1], "both cells reported the same position")
    }

    func testAnEmptyImageYieldsNoCells() {
        let blank = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertTrue(MultiCardDetector.cells(in: blank, context: CIContext()).isEmpty)
    }
}
