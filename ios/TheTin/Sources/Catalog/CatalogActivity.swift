import Foundation

/// Local breadcrumb trail of catalog update operations — which source served what, when, and
/// what failed. Surfaced in Settings so a bad update can be diagnosed from the device instead
/// of server-side forensics (2026-07-18 tier-downgrade incident). Newest first, capped.
@MainActor
enum CatalogActivity {
    /// Overridable for tests; production lives next to the catalog artifact.
    static var url = CatalogPaths.default().directory.appendingPathComponent("activity.log")
    static let cap = 50

    static func record(_ event: String) {
        let df = DateFormatter()
        df.dateFormat = "MMM d HH:mm"
        var lines = read()
        lines.insert("\(df.string(from: Date())) — \(event)", at: 0)
        if lines.count > cap { lines.removeLast(lines.count - cap) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func read() -> [String] {
        (try? String(contentsOf: url, encoding: .utf8))
            .map { $0.split(separator: "\n").map(String.init) } ?? []
    }
}
