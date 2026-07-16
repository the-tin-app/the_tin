import CoreGraphics
import Foundation

struct CanonicalFrame {
    let pixels: Data          // BGRA, bytesPerRow * height
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let focus: Double
    let glareCoverage: Double
    let quadConfidence: Double
}

struct CardQuad {
    let topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint
}
