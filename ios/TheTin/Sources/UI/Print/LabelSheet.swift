import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// The physical geometry of one sheet of label stock, in PostScript points (72 per inch).
///
/// ⚠️ MEASURED vs ASSUMED. `columns`, `rows` and `labelSize` are known: the pack is 2" × 1" and
/// 1200 labels over 30 sheets is 40 up, which on US Letter can only be 4 × 10. The MARGINS are
/// derived arithmetic, not measured — which is exactly why `LabelCalibrationPage` exists and why
/// every sheet takes an offset. Print the calibration page, measure the error, type it in.
struct LabelStock: Equatable {
    let columns: Int
    let rows: Int
    let labelSize: CGSize
    let topMargin: CGFloat
    let leftMargin: CGFloat

    var perSheet: Int { columns * rows }

    /// Spartan Industrial R005 — 2" × 1", 40 per US Letter sheet.
    /// 4 × 2.0" = 8.0", leaving 0.5" split as 0.25" per side; 10 × 1.0" = 10", leaving 0.5" top
    /// and bottom. Zero gap between labels (butt-cut) until a test print says otherwise.
    static let spartanR005 = LabelStock(
        columns: 4, rows: 10,
        labelSize: CGSize(width: 2 * 72, height: 1 * 72),
        topMargin: 0.5 * 72, leftMargin: 0.25 * 72)

    /// Top-left corner of slot `index`, walking left→right then down, shifted by the calibration
    /// offset (points; positive x is right, positive y is down).
    func origin(index: Int, offset: CGSize) -> CGPoint {
        let column = index % columns
        let row = index / columns
        return CGPoint(x: leftMargin + CGFloat(column) * labelSize.width + offset.width,
                       y: topMargin + CGFloat(row) * labelSize.height + offset.height)
    }
}

/// One label's worth of content.
struct LabelItem: Identifiable, Equatable {
    let id: String        // entry id; a ×N entry yields N items sharing it
    let name: String
    let setLine: String   // "Neo Genesis · #5"
    let detail: String    // "Holo · NM"
    let url: URL
}

/// One sheet: a fixed-length array of optional slots, so a blank position is representable.
struct LabelSheetPageModel: Equatable {
    let slots: [LabelItem?]
}

enum LabelSheet {
    /// UserDefaults keys for the calibration offset, in MILLIMETRES (what a ruler reads).
    static let offsetXKey = "labelOffsetXmm"
    static let offsetYKey = "labelOffsetYmm"

    static func pointsPerMM(_ mm: Double) -> CGFloat { CGFloat(mm) * 72.0 / 25.4 }

    /// The persisted calibration offset, converted to points.
    static func savedOffset(_ defaults: UserDefaults = .standard) -> CGSize {
        CGSize(width: pointsPerMM(defaults.double(forKey: offsetXKey)),
               height: pointsPerMM(defaults.double(forKey: offsetYKey)))
    }

    /// Entries → labels, ONE PER PHYSICAL CARD (a ×3 entry gives three identical labels, all
    /// pointing at the same copy). Sold copies get nothing — you don't label a card you sold.
    ///
    /// A card the catalog can't resolve still gets a label, named by its id: the sticker's job is
    /// to identify the thing in your hand, and dropping rows the catalog lost is the wrong failure.
    static func items(entries: [CollectionEntry], cards: [String: CardRecord],
                      setNames: [String: String]) -> [LabelItem] {
        entries.filter { !$0.isSold }.flatMap { entry -> [LabelItem] in
            let card = cards[entry.cardId]
            let setLine = card.map { "\(setNames[$0.setId] ?? $0.setId) · #\($0.number)" } ?? ""
            let detail = [entry.variantValue?.label, entry.condition, entry.gradeValue?.label]
                .compactMap { $0 }.joined(separator: " · ")
            let item = LabelItem(id: entry.id, name: card?.name ?? entry.cardId,
                                 setLine: setLine, detail: detail,
                                 url: LabelPayload.url(for: entry, name: card?.name,
                                                       imageURL: card?.webArtURL?.absoluteString))
            return Array(repeating: item, count: max(entry.qty, 1))
        }
    }

    /// Lay items into sheets. `startPosition` is 1-based and applies to the FIRST sheet only —
    /// later sheets are fresh stock and start at slot 1.
    static func pages(items: [LabelItem], stock: LabelStock,
                      startPosition: Int, offset: CGSize) -> [LabelSheetPageModel] {
        guard !items.isEmpty else { return [] }
        let start = min(max(startPosition, 1), stock.perSheet) - 1
        var out: [LabelSheetPageModel] = []
        var remaining = items[...]
        var skip = start
        while !remaining.isEmpty {
            var slots = [LabelItem?](repeating: nil, count: stock.perSheet)
            for slot in skip..<stock.perSheet {
                guard let next = remaining.first else { break }
                slots[slot] = next
                remaining = remaining.dropFirst()
            }
            out.append(LabelSheetPageModel(slots: slots))
            skip = 0
        }
        return out
    }

    /// QR bitmap at `size` points square, nearest-neighbour scaled so module edges stay hard —
    /// a smoothed QR is a QR that doesn't scan.
    ///
    /// Correction level M: the standard trade-off, and the payload is short enough that it costs
    /// no extra version. Raise to Q only if a real print scans unreliably.
    static func qrImage(for url: URL, size: CGFloat) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// One printed sheet of labels. Absolute positioning, because the grid has to line up with
/// die-cut stock — SwiftUI layout would centre and distribute, which is exactly wrong here.
struct LabelSheetPage: View {
    let page: LabelSheetPageModel
    let stock: LabelStock
    let offset: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(Array(page.slots.enumerated()), id: \.offset) { index, item in
                if let item {
                    let origin = stock.origin(index: index, offset: offset)
                    label(item)
                        .frame(width: stock.labelSize.width, height: stock.labelSize.height)
                        .offset(x: origin.x, y: origin.y)
                }
            }
        }
        .frame(width: SheetPDF.letter.width, height: SheetPDF.letter.height)
        .background(.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }

    /// QR on the left, the rest text. The QR is rasterized at 216 pt (well above its printed size)
    /// and drawn down, so the PDF carries enough resolution for a 300 dpi printer.
    ///
    /// ⚠️ **QR size and text width are the SAME budget.** The label is 2" × 1", so a square QR
    /// grown to fill the height eats that height out of the 2" of width, and the text column is
    /// whatever is left. It is sized here to the full height less the padding — 64 pt of 72, a
    /// ~1.4 mm buffer off each die-cut edge — because scanning it across a table is the sticker's
    /// whole job, and that leaves 68 pt for the text. The type is sized to that 68 pt, not the
    /// other way round.
    ///
    /// A worst-case payload is QR version 9 (53 modules), so 64 pt = 0.889" prints at **16.8 mil**
    /// per module, comfortably above the ~10 mil where phone cameras start to struggle (it was
    /// 14 mil at the original 0.75").
    func label(_ item: LabelItem) -> some View {
        HStack(spacing: 4) {
            if let qr = LabelSheet.qrImage(for: item.url, size: 216) {
                Image(uiImage: qr).resizable().interpolation(.none)
                    .frame(width: 64, height: 64)
            }
            // ⚠️ NOTHING here truncates, deliberately. One line per row cut "Mega Charizard ex"
            // short and — worse — ate the "· #233" off the tail of the set line, which is the
            // part that identifies the copy. Width is the scarce resource; HEIGHT is not (the QR
            // sets the label's height anyway). So every row wraps instead.
            //
            // The limits are the catalog's MEASURED maxima, not guesses: the longest card name is
            // 49 chars ("Team Galactic's Invention G-107 Technical Machine") and the longest set
            // line 39 ("Brilliant Stars Trainer Gallery · #TG21"). At these sizes those need 3 and
            // 2 lines in a 68 pt column; the type shrank when the QR grew, for exactly that reason.
            // `testTheWorstCaseLabelStillFitsItsDieCut` renders both and fails either way — too
            // tall clips the die-cut, too short means a row started truncating again.
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 6.5, weight: .bold)).lineLimit(3)
                Text(item.setLine).font(.system(size: 5.5)).lineLimit(2)
                    .foregroundStyle(.black.opacity(0.7))
                Text(item.detail).font(.system(size: 5.5)).lineLimit(2)
                    .foregroundStyle(.black.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(4)
    }
}

/// The calibration page: every slot outlined with a centre crosshair, plus a millimetre scale down
/// the left edge and across the top. Print on PLAIN paper, hold it against a label sheet, read the
/// error, type it into Settings. This is the whole reason the offset exists — printers differ in
/// their unprintable margin and feed alignment, and no arithmetic fixes that.
struct LabelCalibrationPage: View {
    let stock: LabelStock
    let offset: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(0..<stock.perSheet, id: \.self) { index in
                let origin = stock.origin(index: index, offset: offset)
                ZStack {
                    Rectangle().stroke(.black, lineWidth: 0.5)
                    Path { p in
                        p.move(to: CGPoint(x: stock.labelSize.width / 2, y: 0))
                        p.addLine(to: CGPoint(x: stock.labelSize.width / 2,
                                              y: stock.labelSize.height))
                        p.move(to: CGPoint(x: 0, y: stock.labelSize.height / 2))
                        p.addLine(to: CGPoint(x: stock.labelSize.width,
                                              y: stock.labelSize.height / 2))
                    }
                    .stroke(.black.opacity(0.4), lineWidth: 0.3)
                    Text("\(index + 1)").font(.system(size: 7))
                }
                .frame(width: stock.labelSize.width, height: stock.labelSize.height)
                .offset(x: origin.x, y: origin.y)
            }
            ruler(horizontal: true)
            ruler(horizontal: false)
            Text("Align against a label sheet. Read the error in mm, enter it in Settings → Labels.")
                .font(.system(size: 8))
                .offset(x: 36, y: SheetPDF.letter.height - 24)
        }
        .frame(width: SheetPDF.letter.width, height: SheetPDF.letter.height)
        .background(.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }

    /// Ticks every 1 mm, labelled every 10, running from the page edge.
    private func ruler(horizontal: Bool) -> some View {
        ForEach(0..<200, id: \.self) { mm in
            let d = LabelSheet.pointsPerMM(Double(mm))
            let long = mm % 10 == 0
            Group {
                if horizontal {
                    Rectangle().frame(width: 0.3, height: long ? 8 : 4).offset(x: d, y: 0)
                    if long {
                        Text("\(mm)").font(.system(size: 4)).offset(x: d - 3, y: 9)
                    }
                } else {
                    Rectangle().frame(width: long ? 8 : 4, height: 0.3).offset(x: 0, y: d)
                    if long {
                        Text("\(mm)").font(.system(size: 4)).offset(x: 9, y: d - 2)
                    }
                }
            }
        }
    }
}
