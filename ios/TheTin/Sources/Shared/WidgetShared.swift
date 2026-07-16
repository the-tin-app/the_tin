import Foundation

/// Compiled into BOTH the TheTin and TheTinWidgets targets (project.yml lists this directory in the
/// widget target's sources). Keep it Foundation-only — no app types, no WidgetKit, no SwiftUI —
/// so the extension compiles it standalone.
enum WidgetShared {
    static let appGroupId = "group.ai.reyes.thetin"
    static let snapshotFilename = "widget-snapshot.json"

    static func snapshotURL(container: URL) -> URL {
        container.appendingPathComponent(snapshotFilename)
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// The tin-total currency style the Collection header uses: cents under $1000, whole dollars
    /// at/above. Extracted here so the widget renders the exact same string as the app.
    static func tinCurrency(_ value: Double) -> FloatingPointFormatStyle<Double>.Currency {
        FloatingPointFormatStyle<Double>.Currency(code: "USD")
            .precision(.fractionLength(value < 1000 ? 2 : 0))
    }

    /// "2026-07-12" → "Jul 12" for widget captions. Returns the input unchanged on parse failure.
    static func shortDate(_ asOf: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")
        guard let date = parser.date(from: asOf) else { return asOf }
        // Format in UTC too — the device-local zone would shift dates near midnight (e.g.
        // "2026-07-12" rendering as "Jul 11" west of UTC).
        let style = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!)
            .month(.abbreviated).day()
        return date.formatted(style)
    }
}

/// The app→widget handoff, serialized as widget-snapshot.json in the App Group container.
struct WidgetSnapshot: Codable, Equatable {
    var totalValue: Double
    var cardCount: Int
    /// Fractional 7-day change (0.042 = +4.2%). nil until the portfolio-history feature is
    /// merged and wired (see plan Task 7) — the widget then shows value-only.
    var delta7d: Double?
    /// Last ~12 weekly portfolio values, oldest first. nil when history is unavailable.
    var sparkline: [Double]?
    /// Price-data date "yyyy-MM-dd" (newest as_of across priced cards); nil when nothing priced.
    var asOf: String?
    var updatedAt: Date
}
