import CoreImage
import Foundation

/// DEBUG-only capture of what the binder actually saw, so a device session produces **fixtures** rather
/// than a description of fixtures.
///
/// ⚠️ This exists because of a specific failure mode, not for completeness. On 2026-08-07 a device run
/// came back with a page where readable cards did not identify and a page whose bottom row landed in the
/// wrong pockets — and neither was diagnosable from the report, because the photographs stayed on the
/// phone. The measured 346-cell baseline was shot with the system Camera app, so it cannot stand in for
/// what our own capture pipeline delivers. Every round of inference costs a device session; a
/// full-resolution photograph costs 10 MB.
///
/// Same pattern and same reasoning as `ScanDiag`. Compiled out of Release entirely.
///
/// Pull it with:
/// ```bash
/// xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
///   --domain-identifier ai.reyes.thetin --source "Library/Caches/VirtualBinder/diag" \
///   --destination /tmp/binder-diag
/// ```
///
/// ⚠️ Shoot **one page** for a diagnostic run. Four 48 MP JPEGs is ~40 MB and copies in seconds; a
/// whole binder is hundreds of MB and `devicectl` copies of that size time out (the same trap as
/// copying `Application Support` wholesale).
enum BinderDiag {

    #if DEBUG
    static var directory: URL {
        BinderCache.shared.root.appendingPathComponent("diag", isDirectory: true)
    }
    #endif

    /// The photograph as captured, at full resolution and untouched — this is the replay fixture. The
    /// tile JPEG the app keeps for the verification crop is downscaled to 1,400 px, which is far too
    /// small to reproduce detection against.
    static func record(photo: CIImage, tile: BinderTile) {
        #if DEBUG
        let dir = directory
        Task.detached(priority: .background) {
            guard let data = try? CIContext().jpegRepresentation(
                of: photo, colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95])
            else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("\(tile.id).jpg"), options: .atomic)
        }
        #endif
    }

    /// Every decision the device made about one photograph.
    ///
    /// ⚠️ Recorded rather than re-derived, because it cannot be re-derived:
    /// `VNDetectDocumentSegmentationRequest` is documented in this codebase as non-deterministic over
    /// the same input, so replaying the photograph gives a *different* set of cells. Which pocket the
    /// device put each card in is only knowable from the device.
    static func record(cells: [LensCell], rects: [CGRect], slots: [BinderSlot], tile: BinderTile) {
        #if DEBUG
        struct Row: Encodable {
            let cx: Double, cy: Double, w: Double, h: Double
            let fpCount: Int, state: String, row: Int, col: Int
        }
        let rows = zip(zip(cells, rects), slots).map { pair, slot -> Row in
            let (cell, rect) = pair
            let state: String
            switch cell.state {
            case .identified(let id, let n): state = "identified \(id) (\(n))"
            case .ambiguous(let ids):        state = "ambiguous \(ids.joined(separator: ","))"
            case .unreadable(let why):       state = "unreadable \(why)"
            case .noMatch:                   state = "noMatch"
            case .pending:                   state = "pending"
            }
            return Row(cx: rect.midX, cy: rect.midY, w: rect.width, h: rect.height,
                       fpCount: cell.fpCount, state: state, row: slot.row, col: slot.col)
        }
        let dir = directory
        let name = "\(tile.id).json"
        Task.detached(priority: .background) {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? enc.encode(rows) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
        #endif
    }
}
