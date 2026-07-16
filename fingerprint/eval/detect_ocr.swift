import Foundation
import Vision
import CoreImage
import AppKit

let CANON_W = 660, CANON_H = 920
let inDir = "test_images"        // repo test_images (run from the repo root)
let plateDir = "plates"          // scratch output dir, created below
try? FileManager.default.createDirectory(atPath: plateDir, withIntermediateDirectories: true)
let ctx = CIContext()

// ROIs (Vision normalized, bottom-left origin) — TextGate's + an HP ROI.
let numberROI = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.13)
let nameROI   = CGRect(x: 0.05, y: 0.86, width: 0.75, height: 0.10)
let hpROI     = CGRect(x: 0.55, y: 0.88, width: 0.45, height: 0.10)

func ocr(_ cg: CGImage, _ roi: CGRect) -> String {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.regionOfInterest = roi
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    return (req.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: " ")
}

func cgFromCI(_ ci: CIImage) -> CGImage? { ctx.createCGImage(ci, from: ci.extent) }

// Score how "upright" an image is by total OCR confidence (upright card text reads best).
func uprightScore(_ cg: CGImage) -> Double {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .fast
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    return (req.results ?? []).reduce(0.0) { $0 + Double($1.topCandidates(1).first?.confidence ?? 0) }
}

func rotate(_ ci: CIImage, _ deg: Int) -> CIImage {
    let r = CGFloat(deg) * .pi / 180
    let t = CGAffineTransform(rotationAngle: r)
    let out = ci.transformed(by: t)
    return out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
}

// Perspective-corrected (any orientation) -> upright 660x920 portrait plate.
func orientUpright(_ corrected: CIImage) -> CGImage? {
    // If landscape, the two candidate uprights are 90 and 270; if portrait, 0 and 180.
    let cands = corrected.extent.width > corrected.extent.height ? [90, 270] : [0, 180]
    var best: (Double, CIImage)? = nil
    for d in cands {
        let r = rotate(corrected, d)
        guard let cg = cgFromCI(r) else { continue }
        let s = uprightScore(cg)
        if best == nil || s > best!.0 { best = (s, r) }
    }
    guard let chosen = best?.1 else { return nil }
    let scaled = chosen.transformed(by: CGAffineTransform(scaleX: CGFloat(CANON_W)/chosen.extent.width,
                                                          y: CGFloat(CANON_H)/chosen.extent.height))
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

// Detect the best card-shaped quad; perspective-correct to canonical plate.
func rectify(_ cg: CGImage) -> (CIImage, Double)? {
    let ci = CIImage(cgImage: cg)
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    // Prefer the strong document-segmentation detector (robust to low contrast / glare /
    // rounded toploader corners / full-art borders). Fall back to rectangle detection.
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
    // pick highest-confidence obs whose real (pixel) aspect looks card-like (short/long in 0.60..0.85)
    func aspect(_ o: VNRectangleObservation) -> Double {
        let tl = px(o.topLeft), tr = px(o.topRight), bl = px(o.bottomLeft)
        let w = hypot(tr.x-tl.x, tr.y-tl.y), h = hypot(bl.x-tl.x, bl.y-tl.y)
        let lo = min(w,h), hi = max(w,h); return hi > 0 ? Double(lo/hi) : 0
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
    return (out, Double(chosen.confidence))   // natural aspect, orientation resolved later
}

let nums = (try? FileManager.default.contentsOfDirectory(atPath: inDir))?
    .compactMap { (name: String) -> String? in
        guard name.hasPrefix("IMG_"), name.hasSuffix(".png") else { return nil }
        return String(name.dropFirst(4).dropLast(4))
    }
    .sorted { (Int($0) ?? 0) < (Int($1) ?? 0) } ?? []

var out: [[String: Any]] = []
for num in nums {
    guard let cg = loadCG("\(inDir)/IMG_\(num).png") else { continue }
    guard let (correctedCI, conf) = rectify(cg), let plateCG = orientUpright(correctedCI) else {
        out.append(["num": num, "detected": false]); print("\(num): NO-DETECT"); continue
    }
    writePNG(plateCG, "\(plateDir)/\(num).png")
    let full = ocr(plateCG, CGRect(x: 0, y: 0, width: 1, height: 1))
    out.append(["num": num, "detected": true, "conf": conf, "text": full])
    print("\(num): det=\(String(format: "%.2f", conf)) | \(full.prefix(90))")
}
let js = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted])
try js.write(to: URL(fileURLWithPath: "ocr_results.json"))
print("\nwrote ocr_results.json (\(out.count) images), plates in \(plateDir)")
