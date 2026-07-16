// Generates the 64 canonical 660x920 scan-photo plates for the iOS accuracy fixture
// (ios/TheTin/Tests/Fixtures/ScanPhotos/IMG_<num>.pngdata), using the SAME doc-seg detect +
// orientation-normalize algorithm as production `CardDetector` (ios/TheTin/Sources/Scanner/
// CardDetector.swift's CardRectifier + OrientationNormalizer) — this file's rectify()/
// orientUpright() are the reference those were ported from 1:1 (see CardDetector.swift's doc
// comments), so this is a faithful stand-in for running the real Swift type outside Xcode.
//
// Run: swift fingerprint/eval/make_scan_plates.swift
// Reads: test_images/*.png + ios/TheTin/Tests/Fixtures/ScanPhotos/labels.json (for the photo
// list). Writes: ios/TheTin/Tests/Fixtures/ScanPhotos/IMG_<num>.pngdata (PNG bytes).
import Foundation
import Vision
import CoreImage
import AppKit

let CANON_W = 660, CANON_H = 920
let root = FileManager.default.currentDirectoryPath  // run from the repo root
let srcDir = "\(root)/test_images"
let outDir = "\(root)/ios/TheTin/Tests/Fixtures/ScanPhotos"
let ctx = CIContext()

func ocr(_ cg: CGImage, _ roi: CGRect, level: VNRequestTextRecognitionLevel = .fast) -> String {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = level
    req.regionOfInterest = roi
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    return (req.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: " ")
}

func cgFromCI(_ ci: CIImage) -> CGImage? { ctx.createCGImage(ci, from: ci.extent) }

func uprightScore(_ cg: CGImage) -> Double {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .fast
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    return (req.results ?? []).reduce(0.0) { $0 + Double($1.topCandidates(1).first?.confidence ?? 0) }
}

func rotate(_ ci: CIImage, _ deg: Int) -> CIImage {
    let r = CGFloat(deg) * .pi / 180
    let out = ci.transformed(by: CGAffineTransform(rotationAngle: r))
    return out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
}

// Perspective-corrected (any orientation) -> upright 660x920 portrait plate. Mirrors
// OrientationNormalizer.orientUpright.
func orientUpright(_ corrected: CIImage) -> CGImage? {
    let cands = corrected.extent.width > corrected.extent.height ? [90, 270] : [0, 180]
    var best: (Double, CIImage)? = nil
    for d in cands {
        let r = rotate(corrected, d)
        guard let cg = cgFromCI(r) else { continue }
        let s = uprightScore(cg)
        if best == nil || s > best!.0 { best = (s, r) }
    }
    guard let chosen = best?.1 else { return nil }
    let scaled = chosen.transformed(by: CGAffineTransform(scaleX: CGFloat(CANON_W) / chosen.extent.width,
                                                          y: CGFloat(CANON_H) / chosen.extent.height))
    return cgFromCI(scaled)
}

func loadCG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func writePNG(_ cg: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: cg)
    if let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: URL(fileURLWithPath: path)) }
}

// Detect the best card-shaped quad; perspective-correct to natural-aspect CIImage. Mirrors
// CardRectifier.rectify (doc-seg preferred, VNDetectRectangles fallback, same params).
// ponytail: hand-port of ios CardRectifier.rectify — a standalone `swift` script can't
// @testable import TheTin, so there's no parity guard. If CardRectifier/OrientationNormalizer
// change, regenerate the plate fixtures from here and re-run LabeledPhotoAccuracyTests; a
// silent drift only surfaces as accuracy drift, not a build/parity failure.
func rectify(_ cg: CGImage) -> (CIImage, Double)? {
    let ci = CIImage(cgImage: cg)
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    var obs: [VNRectangleObservation] = []
    let docReq = VNDetectDocumentSegmentationRequest()
    try? handler.perform([docReq])
    if let d = docReq.results, !d.isEmpty { obs = d }
    else {
        let rreq = VNDetectRectanglesRequest()
        rreq.minimumConfidence = 0.3; rreq.minimumAspectRatio = 0.4; rreq.maximumAspectRatio = 0.95
        rreq.maximumObservations = 12; rreq.quadratureTolerance = 40; rreq.minimumSize = 0.15
        try? handler.perform([rreq])
        obs = rreq.results ?? []
    }
    guard !obs.isEmpty else { return nil }
    let ext = ci.extent
    func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * ext.width, y: p.y * ext.height) }
    func aspect(_ o: VNRectangleObservation) -> Double {
        let tl = px(o.topLeft), tr = px(o.topRight), bl = px(o.bottomLeft)
        let w = hypot(tr.x - tl.x, tr.y - tl.y), h = hypot(bl.x - tl.x, bl.y - tl.y)
        let lo = min(w, h), hi = max(w, h); return hi > 0 ? Double(lo / hi) : 0
    }
    let cardish = obs.filter { (0.58...0.86).contains(aspect($0)) }
    let chosen = (cardish.isEmpty ? obs : cardish).max { Double($0.confidence) < Double($1.confidence) }!
    let f = CIFilter(name: "CIPerspectiveCorrection")!
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(CIVector(cgPoint: px(chosen.topLeft)), forKey: "inputTopLeft")
    f.setValue(CIVector(cgPoint: px(chosen.topRight)), forKey: "inputTopRight")
    f.setValue(CIVector(cgPoint: px(chosen.bottomLeft)), forKey: "inputBottomLeft")
    f.setValue(CIVector(cgPoint: px(chosen.bottomRight)), forKey: "inputBottomRight")
    guard let out = f.outputImage else { return nil }
    return (out, Double(chosen.confidence))
}

func heicPath(forNum num: String) -> String? {
    let plain = "\(srcDir)/IMG_\(num).png"
    if FileManager.default.fileExists(atPath: plain) { return plain }
    let dup = "\(srcDir)/IMG_\(num) 2.png"
    if FileManager.default.fileExists(atPath: dup) { return dup }
    return nil
}

// MARK: - main

struct Label: Decodable { let plate: String; let truthIds: [String]; let condition: String }

let labelsURL = URL(fileURLWithPath: "\(outDir)/labels.json")
let labels = try! JSONDecoder().decode([Label].self, from: Data(contentsOf: labelsURL))
print("generating \(labels.count) plates from \(srcDir) -> \(outDir)")

var failures: [String] = []
for label in labels {
    let num = String(label.plate.dropFirst("IMG_".count))
    guard let path = heicPath(forNum: num) else { failures.append("\(label.plate): source HEIC not found"); continue }
    guard let cg = loadCG(path) else { failures.append("\(label.plate): failed to decode HEIC"); continue }
    guard let (correctedCI, conf) = rectify(cg) else { failures.append("\(label.plate): NO-DETECT"); continue }
    guard let plateCG = orientUpright(correctedCI) else { failures.append("\(label.plate): orient failed"); continue }
    writePNG(plateCG, "\(outDir)/\(label.plate).pngdata")
    print("\(label.plate): det=\(String(format: "%.2f", conf)) OK")
}

if !failures.isEmpty {
    print("\nFAILURES (\(failures.count)):")
    for f in failures { print("  \(f)") }
    exit(1)
}
print("\nwrote \(labels.count) plates to \(outDir)")
