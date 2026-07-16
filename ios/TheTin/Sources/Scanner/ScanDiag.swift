import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if DEBUG
/// Debug-only heavy-frame diagnostics dump: writes each heavy frame's canonical plate PNG plus
/// a jsonl line (focus/glare, OCR text, pool size, top match results, emitted event) to
/// Application Support/ScanDiag/, ring-buffered to the newest `cap` frames. Pull from a device
/// with:
///   xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
///     --domain-identifier ai.reyes.thetin --source "Library/Application Support/ScanDiag" \
///     --destination /tmp/scandiag
/// Exists because idevicesyslog cannot stream this phone (CoreDevice tunnel) — live-frame
/// evidence has to leave the device as files. Not compiled into Release.
enum ScanDiag {
    private static let cap = 40
    private static var seq = 0
    private static let dir: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("ScanDiag", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func dump(frame: CanonicalFrame, fields: OcrFields, pool: [String],
                     results: [MatchCandidate], event: ScanEvent?) {
        guard let dir else { return }
        seq += 1
        let name = String(format: "%04d", seq)

        if let cg = cgImage(from: frame),
           let dest = CGImageDestinationCreateWithURL(
               dir.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }

        let line: [String: Any] = [
            "n": seq,
            "focus": Int(frame.focus), "glare": frame.glareCoverage,
            "quadConf": frame.quadConfidence,
            "ocr": fields.rawText, "numerators": fields.numerators,
            "denom": fields.denominator ?? "", "hp": fields.hp ?? -1,
            "pool": pool.count,
            "top": results.prefix(5).map { "\($0.cardId):\($0.inliers)" },
            "event": String(describing: event),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: line),
           let text = String(data: data, encoding: .utf8) {
            let url = dir.appendingPathComponent("diag.jsonl")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data((text + "\n").utf8)); try? h.close()
            } else {
                try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }

        // Ring buffer: drop the oldest plates beyond cap (jsonl stays — it's tiny).
        if seq > cap {
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent(String(format: "%04d.png", seq - cap)))
        }
    }

    private static func cgImage(from plate: CanonicalFrame) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info: CGBitmapInfo = [.byteOrder32Little,
                                  CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
        guard let provider = CGDataProvider(data: plate.pixels as CFData) else { return nil }
        return CGImage(width: plate.width, height: plate.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: plate.bytesPerRow, space: cs, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
#endif
