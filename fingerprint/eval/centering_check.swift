// Offline check of the centring measurement against the real photos in ../../test_images.
//
// Run from the repo root:  swift fingerprint/eval/centering_check.swift
//
// The walk below is a verbatim copy of `CenteringMeter.measure` in
// ios/TheTin/Sources/Scanner/Centering.swift — same constants, same order — so what this
// prints is what the app computes. It exists because the app can only show a number, and a
// number cannot be checked by eye. This writes `centering_out/<name>.png`: the canonical plate
// with the four measured border edges drawn on it, which CAN be checked by eye.
import Foundation
import Vision
import CoreImage
import AppKit

let CANON_W = 660, CANON_H = 920
let inDir = "test_images"
let outDir = "centering_out"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let ctx = CIContext()

// ── Centering.swift, copied ──────────────────────────────────────────────────────────────
let edgeSkip = 3
let channelDelta = 40.0
let runLength = 3
let searchFraction = 0.25
let scanlines = 9

struct Centering { let left: Int, right: Int, top: Int, bottom: Int }

func measure(bgra: Data, width: Int, height: Int, bytesPerRow: Int) -> Centering? {
    guard width > 8, height > 8, bgra.count >= bytesPerRow * height else { return nil }
    return bgra.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Centering? in
        let p = raw.bindMemory(to: UInt8.self)
        func bgr(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = y * bytesPerRow + x * 4
            return (Double(p[i]), Double(p[i + 1]), Double(p[i + 2]))
        }
        func differs(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Bool {
            max(abs(a.0 - b.0), max(abs(a.1 - b.1), abs(a.2 - b.2))) > channelDelta
        }
        func borderWidth(limit: Int, pixel: (Int) -> (Double, Double, Double)) -> Int? {
            let reference = pixel(edgeSkip)
            var run = 0
            for depth in (edgeSkip + 1)..<limit {
                if differs(pixel(depth), reference) {
                    run += 1
                    if run == runLength { return depth - runLength + 1 }
                } else { run = 0 }
            }
            return nil
        }
        func edge(limit: Int, span: Int, pixel: @escaping (Int, Int) -> (Double, Double, Double)) -> Int? {
            var widths: [Int] = []
            for n in 0..<scanlines {
                let along = span / 4 + (span / 2) * n / (scanlines - 1)
                if let w = borderWidth(limit: limit, pixel: { pixel($0, min(along, span - 1)) }) {
                    widths.append(w)
                }
            }
            guard widths.count > scanlines / 2 else { return nil }
            widths.sort()
            return widths[widths.count / 2]
        }
        let hLimit = Int(Double(width) * searchFraction)
        let vLimit = Int(Double(height) * searchFraction)
        guard let left = edge(limit: hLimit, span: height, pixel: { bgr($0, $1) }),
              let right = edge(limit: hLimit, span: height, pixel: { bgr(width - 1 - $0, $1) }),
              let top = edge(limit: vLimit, span: width, pixel: { bgr($1, $0) }),
              let bottom = edge(limit: vLimit, span: width, pixel: { bgr($1, height - 1 - $0) })
        else { return nil }
        return Centering(left: left, right: right, top: top, bottom: bottom)
    }
}

func skew(_ tl: CGPoint, _ tr: CGPoint, _ bl: CGPoint, _ br: CGPoint) -> Double {
    func len(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(b.x - a.x, b.y - a.y)) }
    func dis(_ a: Double, _ b: Double) -> Double { let m = max(a, b); return m > 0 ? abs(a - b) / m : 0 }
    return max(dis(len(tl, tr), len(bl, br)), dis(len(tl, bl), len(tr, br)))
}
// ─────────────────────────────────────────────────────────────────────────────────────────

func rotate(_ ci: CIImage, _ deg: Int) -> CIImage {
    let out = ci.transformed(by: CGAffineTransform(rotationAngle: CGFloat(deg) * .pi / 180))
    return out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
}

func uprightScore(_ cg: CGImage) -> Double {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .fast
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    return (req.results ?? []).reduce(0.0) { $0 + Double($1.topCandidates(1).first?.confidence ?? 0) }
}

/// Plate + the quad's skew, mirroring CardRectifier.rectify + OrientationNormalizer.
func plate(_ url: URL) -> (Data, Double)? {
    guard let ci = CIImage(contentsOf: url) else { return nil }
    let ext = ci.extent
    let handler = VNImageRequestHandler(ciImage: ci, options: [:])
    let doc = VNDetectDocumentSegmentationRequest()
    try? handler.perform([doc])
    guard let o = (doc.results ?? []).first(where: { $0.confidence >= 0.3 }) else { return nil }
    func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * ext.width, y: p.y * ext.height) }
    let tl = px(o.topLeft), tr = px(o.topRight), bl = px(o.bottomLeft), br = px(o.bottomRight)
    guard let f = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(CIVector(cgPoint: tl), forKey: "inputTopLeft")
    f.setValue(CIVector(cgPoint: tr), forKey: "inputTopRight")
    f.setValue(CIVector(cgPoint: bl), forKey: "inputBottomLeft")
    f.setValue(CIVector(cgPoint: br), forKey: "inputBottomRight")
    guard let corrected = f.outputImage else { return nil }

    let candidates = corrected.extent.width > corrected.extent.height ? [90, 270] : [0, 180]
    var best: (Double, CIImage)?
    for d in candidates {
        let r = rotate(corrected, d)
        guard let cg = ctx.createCGImage(r, from: r.extent) else { continue }
        let s = uprightScore(cg)
        if best == nil || s > best!.0 { best = (s, r) }
    }
    guard let chosen = best?.1 else { return nil }
    let scaled = chosen.transformed(by: CGAffineTransform(
        scaleX: CGFloat(CANON_W) / chosen.extent.width, y: CGFloat(CANON_H) / chosen.extent.height))
    let stride = CANON_W * 4
    var buf = [UInt8](repeating: 0, count: stride * CANON_H)
    buf.withUnsafeMutableBytes { raw in
        ctx.render(scaled, toBitmap: raw.baseAddress!, rowBytes: stride,
                   bounds: CGRect(x: 0, y: 0, width: CANON_W, height: CANON_H),
                   format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
    return (Data(buf), skew(tl, tr, bl, br))
}

/// Writes the plate with the measured border edges drawn, so the number can be checked by eye.
func writeOverlay(_ bgra: Data, _ c: Centering, to path: String) {
    var pixels = [UInt8](bgra)
    let stride = CANON_W * 4
    func line(x0: Int, x1: Int, y0: Int, y1: Int) {
        for y in max(0, y0)...min(CANON_H - 1, y1) {
            for x in max(0, x0)...min(CANON_W - 1, x1) {
                let i = y * stride + x * 4
                pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 255   // BGRA red
            }
        }
    }
    line(x0: c.left, x1: c.left + 1, y0: 0, y1: CANON_H - 1)
    line(x0: CANON_W - 1 - c.right - 1, x1: CANON_W - 1 - c.right, y0: 0, y1: CANON_H - 1)
    line(x0: 0, x1: CANON_W - 1, y0: c.top, y1: c.top + 1)
    line(x0: 0, x1: CANON_W - 1, y0: CANON_H - 1 - c.bottom - 1, y1: CANON_H - 1 - c.bottom)

    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let cg = CGImage(width: CANON_W, height: CANON_H, bitsPerComponent: 8, bitsPerPixel: 32,
                     bytesPerRow: stride, space: cs,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue),
                     provider: provider, decode: nil, shouldInterpolate: false,
                     intent: .defaultIntent)!
    let rep = NSBitmapImageRep(cgImage: cg)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

// Labels, so the sleeved/toploader cases can be told apart from bare ones.
var condition: [String: String] = [:]
if let csv = try? String(contentsOfFile: "\(inDir)/images.csv", encoding: .utf8) {
    for row in csv.split(separator: "\n").dropFirst() {
        let f = row.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if f.count >= 6 { condition[f[0]] = f[5] }
    }
}

let files = (try? FileManager.default.contentsOfDirectory(atPath: inDir))?
    .filter { $0.hasSuffix(".png") }.sorted() ?? []
print("image,condition,skew,left,right,top,bottom,L-R,T-B")
for name in files {
    guard let (bgra, sk) = plate(URL(fileURLWithPath: "\(inDir)/\(name)")) else {
        print("\(name),\(condition[name] ?? "?"),DETECT-FAILED,,,,,,"); continue
    }
    guard let c = measure(bgra: bgra, width: CANON_W, height: CANON_H, bytesPerRow: CANON_W * 4) else {
        print("\(name),\(condition[name] ?? "?"),\(String(format: "%.3f", sk)),UNREADABLE,,,,,"); continue
    }
    let h = Int((Double(c.left) / Double(c.left + c.right) * 100).rounded())
    let v = Int((Double(c.top) / Double(c.top + c.bottom) * 100).rounded())
    print("\(name),\(condition[name] ?? "?"),\(String(format: "%.3f", sk)),"
          + "\(c.left),\(c.right),\(c.top),\(c.bottom),\(h)/\(100 - h),\(v)/\(100 - v)")
    writeOverlay(bgra, c, to: "\(outDir)/\(name)")
}
