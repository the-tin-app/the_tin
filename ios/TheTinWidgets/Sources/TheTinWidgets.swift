import WidgetKit
import SwiftUI

@main
struct TheTinWidgetsBundle: WidgetBundle {
    var body: some Widget { CollectionValueWidget() }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?   // nil ⇒ app never wrote one ⇒ "Open The Tin to sync"
}

struct SnapshotProvider: TimelineProvider {
    /// Gallery/redaction sample — realistic, obviously fake.
    static let placeholderSnapshot = WidgetSnapshot(
        totalValue: 4806, cardCount: 312, delta7d: 0.042,
        sparkline: [4390, 4420, 4380, 4510, 4560, 4530, 4610, 4640, 4700, 4680, 4750, 4806],
        asOf: "2026-07-12", updatedAt: .now)

    static func loadSnapshot() -> WidgetSnapshot? {
        guard let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: WidgetShared.appGroupId),
              let data = try? Data(contentsOf: WidgetShared.snapshotURL(container: container))
        else { return nil }
        return try? WidgetShared.decoder().decode(WidgetSnapshot.self, from: data)
    }

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: Self.placeholderSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(
            date: .now,
            snapshot: context.isPreview ? Self.placeholderSnapshot : Self.loadSnapshot()))
    }

    /// Static timeline: the value only changes when the app writes a new snapshot and calls
    /// reloadAllTimelines() — WidgetKit then re-asks. No time-based refresh (spec).
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [SnapshotEntry(date: .now, snapshot: Self.loadSnapshot())],
                            policy: .never))
    }
}

struct CollectionValueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CollectionValue", provider: SnapshotProvider()) { entry in
            CollectionValueView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Tin value")
        .description("Your collection's total value at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct CollectionValueView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let snap = entry.snapshot {
            switch family {
            case .accessoryInline: InlineView(snap: snap)
            case .accessoryRectangular: RectangularView(snap: snap)
            case .systemMedium: MediumView(snap: snap)
            default: SmallView(snap: snap)
            }
        } else {
            Text("Open The Tin to sync")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// "▲ 4.2%" / "▼ 1.3%", green/red — same glyphs GroupPagerView's delta row uses.
/// VoiceOver reads the triangle literally ("black up-pointing triangle"), so spell it out.
struct DeltaText: View {
    let delta: Double
    var body: some View {
        Text("\(delta >= 0 ? "▲" : "▼") \(abs(delta), format: .percent.precision(.fractionLength(1)))")
            .foregroundStyle(delta >= 0 ? .green : .red)
            .accessibilityLabel("\(delta >= 0 ? "Up" : "Down") \(abs(delta).formatted(.percent.precision(.fractionLength(1)))) this week")
    }
}

private func captionLine(_ snap: WidgetSnapshot) -> String {
    var line = "\(snap.cardCount) cards"
    if let asOf = snap.asOf { line += " · as of \(WidgetShared.shortDate(asOf))" }
    return line
}

struct SmallView: View {
    let snap: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("THE TIN").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(snap.totalValue, format: WidgetShared.tinCurrency(snap.totalValue))
                .font(.system(.title2, design: .rounded).weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.6)
                .privacySensitive()
            if let d = snap.delta7d {
                DeltaText(delta: d).font(.caption.weight(.semibold)).privacySensitive()
            }
            Spacer(minLength: 0)
            Text(captionLine(snap)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MediumView: View {
    let snap: WidgetSnapshot
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("THE TIN").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(snap.totalValue, format: WidgetShared.tinCurrency(snap.totalValue))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .privacySensitive()
                if let d = snap.delta7d {
                    HStack(spacing: 3) {
                        DeltaText(delta: d)
                        Text("this week").foregroundStyle(.secondary)
                    }
                    .font(.caption.weight(.semibold))
                    .privacySensitive()
                }
                Spacer(minLength: 0)
                Text(captionLine(snap)).font(.caption2).foregroundStyle(.secondary)
            }
            if let values = snap.sparkline, values.count > 1 {
                Sparkline(values: values)
                    .stroke(.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round,
                                                       lineJoin: .round))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct RectangularView: View {
    let snap: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("THE TIN").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(snap.totalValue, format: WidgetShared.tinCurrency(snap.totalValue))
                    .font(.headline.weight(.bold))
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let d = snap.delta7d {
                    Text("\(d >= 0 ? "▲" : "▼") \(abs(d), format: .percent.precision(.fractionLength(1)))")
                        .font(.caption2.weight(.semibold))
                        .accessibilityLabel("\(d >= 0 ? "Up" : "Down") \(abs(d).formatted(.percent.precision(.fractionLength(1)))) this week")
                }
            }
            .privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InlineView: View {
    let snap: WidgetSnapshot
    var body: some View {
        // Inline is a single text line next to the clock; keep it terse.
        (snap.delta7d.map { d in
            Text("Tin \(snap.totalValue, format: WidgetShared.tinCurrency(snap.totalValue)) \(d >= 0 ? "▲" : "▼")\(abs(d), format: .percent.precision(.fractionLength(1)))")
        } ?? Text("Tin \(snap.totalValue, format: WidgetShared.tinCurrency(snap.totalValue))"))
            .privacySensitive()
    }
}

/// Dependency-free weekly sparkline (values oldest→newest, normalized to its own min/max).
struct Sparkline: Shape {
    let values: [Double]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, let lo = values.min(), let hi = values.max() else { return path }
        let span = hi - lo
        let points = values.enumerated().map { i, v in
            CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1),
                    y: span == 0 ? rect.midY
                                 : rect.maxY - rect.height * CGFloat((v - lo) / span))
        }
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        return path
    }
}

#Preview("small", as: .systemSmall) { CollectionValueWidget() } timeline: {
    SnapshotEntry(date: .now, snapshot: SnapshotProvider.placeholderSnapshot)
    SnapshotEntry(date: .now, snapshot: nil)   // empty state
}

#Preview("medium", as: .systemMedium) { CollectionValueWidget() } timeline: {
    SnapshotEntry(date: .now, snapshot: SnapshotProvider.placeholderSnapshot)
    SnapshotEntry(date: .now,
                  snapshot: WidgetSnapshot(totalValue: 4806, cardCount: 312, delta7d: nil,
                                           sparkline: nil, asOf: "2026-07-12",
                                           updatedAt: .now))   // value-only (no history yet)
}

#Preview("lock", as: .accessoryRectangular) { CollectionValueWidget() } timeline: {
    SnapshotEntry(date: .now, snapshot: SnapshotProvider.placeholderSnapshot)
    SnapshotEntry(date: .now, snapshot: nil)
}
