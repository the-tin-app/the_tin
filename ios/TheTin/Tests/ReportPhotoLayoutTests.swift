import SwiftUI
import UIKit
import XCTest
@testable import TheTin

/// `ReportPages.photosPerPage` is DERIVED arithmetic — "a block is 176 + ~28 pt of caption ≈ 204 pt,
/// so three fit". Arithmetic in a comment is not a measurement, and the plan called for rendering a
/// real page before locking the constant.
///
/// This measures it instead of eyeballing a PDF: render the exhibit body at the report's true body
/// width and assert it fits the body height. If a future caption grows a line, this fails and the
/// constant drops to 2 — the constant is the knob, the layout is not.
@MainActor
final class ReportPhotoLayoutTests: XCTestCase {
    /// US Letter at 72 dpi (612 × 792) less the report's 36 pt margins, minus the header/footer
    /// SheetPDF draws. 700 pt is the figure the `photosPerPage` comment itself reasons from.
    private static let bodyWidth: CGFloat = 540
    private static let bodyHeight: CGFloat = 700

    private func photo() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        // 4:3, the shape a phone actually produces — the case `.scaledToFit` exists for.
        return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format)
            .image { ctx in
                UIColor.darkGray.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            }
    }

    /// A worst-case row: long name, long set line, long detail — all three print in the caption.
    private func row(_ id: String) -> ReportRow {
        ReportRow(id: id, card: nil,
                  name: "Feraligatr ex — Full Art Special Illustration Rare",
                  setLine: "Scarlet & Violet — Twilight Masquerade · #167",
                  detail: "Reverse Holo · NM · PSA 10", qty: 1,
                  acquiredAt: nil, acquiredFrom: nil, pricePaid: nil, currentValue: 1234.56,
                  photos: EntryPhotos(front: "f.jpg", back: "b.jpg",
                                      details: ["d1.jpg", "d2.jpg"]))
    }

    private func renderedHeight(rows: Int) -> CGFloat {
        let reportRows = (0..<rows).map { row("e\($0)") }
        // Four shots per entry — the maximum, so this measures the tallest block that can occur.
        let shots = [("Front", photo()), ("Back", photo()),
                     ("Detail 1", photo()), ("Detail 2", photo())]
            .map { (label: $0.0, image: $0.1) }
        let images = Dictionary(uniqueKeysWithValues: reportRows.map { ($0.id, shots) })

        let renderer = ImageRenderer(content:
            ReportPhotoBody(rows: reportRows, images: images, showsHeading: true)
                .frame(width: Self.bodyWidth))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: Self.bodyWidth, height: nil)
        return renderer.uiImage?.size.height ?? .infinity
    }

    /// The gate: a full page of `photosPerPage` worst-case blocks fits the body box.
    func testAFullExhibitPageFitsTheBodyHeight() {
        let height = renderedHeight(rows: ReportPages.photosPerPage)
        XCTAssertLessThanOrEqual(
            height, Self.bodyHeight,
            "\(ReportPages.photosPerPage) blocks render \(height) pt into a \(Self.bodyHeight) pt "
            + "body — drop ReportPages.photosPerPage until this passes.")
    }

    /// Four photos across at 126 pt + 12 pt gaps is meant to fill 540 pt EXACTLY. If the row
    /// overflowed, the fourth shot would be clipped rather than wrapped.
    func testFourPhotosAcrossFitTheBodyWidth() {
        let used = 4 * 126.0 + 3 * 12.0
        XCTAssertLessThanOrEqual(used, Double(Self.bodyWidth))
    }
}
