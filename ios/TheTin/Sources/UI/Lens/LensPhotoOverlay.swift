import CoreImage
import SwiftUI

/// One photo with every detected card outlined — wishlist hits filled, the rest hairline.
/// This is the map, not the UI: the list is where decisions get made, this is how you find the
/// card again in a case with forty in it.
struct LensPhotoOverlay: View {
    let image: CIImage
    let cells: [LensCell]
    var highlighted: UUID?

    /// Rendered ONCE, downscaled, off the MainActor. A full 12 MP CGImage is ~48 MB resident and
    /// `CIContext().createCGImage` inside `body` would re-render it on every pass — this screen
    /// only ever shows the photo a few hundred points wide. Jetsam is uncatchable by Crashlytics.
    @State private var rendered: CGImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let rendered {
                    Image(decorative: rendered, scale: 1, orientation: .up)
                        .resizable().scaledToFit()
                } else {
                    ProgressView()
                }
                ForEach(cells) { cell in
                    let r = rect(for: cell, in: geo.size)
                    Rectangle()
                        .stroke(cell.onWishlist ? Color.accentColor : .white.opacity(0.55),
                                lineWidth: cell.id == highlighted ? 4 : 2)
                        .background(cell.onWishlist ? Color.accentColor.opacity(0.18) : .clear)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task { await render() }
    }

    private func render() async {
        guard rendered == nil else { return }
        let source = image
        rendered = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let ext = source.extent
            guard ext.width > 0, ext.height > 0 else { return nil }
            let s = min(1, 1_400 / max(ext.width, ext.height))
            let scaled = source.transformed(by: CGAffineTransform(scaleX: s, y: s))
            return CIContext().createCGImage(scaled, from: scaled.extent)
        }.value
    }

    /// `scaledToFit` letterboxes, so the drawn image is NOT the geometry's full size — scaling the
    /// quad by `geo.size / extent` would put every outline in the wrong place on any container
    /// whose aspect ratio isn't the photo's. Vision's pixel space is also bottom-left origin
    /// against SwiftUI's top-left, so y is flipped.
    private func rect(for cell: LensCell, in size: CGSize) -> CGRect {
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return .zero }
        let scale = min(size.width / ext.width, size.height / ext.height)
        let drawn = CGSize(width: ext.width * scale, height: ext.height * scale)
        let originX = (size.width - drawn.width) / 2
        let originY = (size.height - drawn.height) / 2

        let q = cell.quad
        let xs = [q.topLeft.x, q.topRight.x, q.bottomLeft.x, q.bottomRight.x]
        let ys = [q.topLeft.y, q.topRight.y, q.bottomLeft.y, q.bottomRight.y]
        let minX = ((xs.min() ?? 0) - ext.minX) * scale
        let maxX = ((xs.max() ?? 0) - ext.minX) * scale
        let minY = ((ys.min() ?? 0) - ext.minY) * scale
        let maxY = ((ys.max() ?? 0) - ext.minY) * scale
        return CGRect(x: originX + minX, y: originY + drawn.height - maxY,
                      width: maxX - minX, height: maxY - minY)
    }
}
