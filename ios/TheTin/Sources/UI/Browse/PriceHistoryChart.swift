import SwiftUI
import Charts

/// Interactive price-history chart. `series[0]` (raw market) gets a gradient area fill; any extra
/// series (expert-tier NM / PSA 10 overlays) draw as plain colored lines with a legend. A range
/// control clips to the trailing 1/3/6 months, and dragging scrubs a value/date callout.
struct PriceHistoryChart: View {
    let series: [PriceSeries]
    /// Portfolio screen hides this and owns its own range control (its stat row needs the
    /// selected range). Defaults to true so card detail is unchanged.
    var showsRangePicker: Bool = true
    @State private var range: TimeRange = .all
    @State private var selectedDate: Date?

    enum TimeRange: String, CaseIterable, Identifiable {
        case m1 = "1M", m3 = "3M", m6 = "6M", all = "All"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .m1: return 30
            case .m3: return 90
            case .m6: return 180
            case .all: return nil
            }
        }
    }

    // Colors keyed by series name so plot and legend agree.
    private func color(_ name: String) -> Color {
        switch name {
        case "NM": return .teal
        case "PSA 10": return .orange
        case "Cost basis": return .gray
        default: return .accentColor
        }
    }

    /// Latest date in the primary series — the range anchor (data can be stale, so anchor to the
    /// data, not "now").
    private var anchorDate: Date? { series.first?.points.last?.date }

    private func clipped(_ points: [PricePoint]) -> [PricePoint] {
        guard let days = range.days, let anchor = anchorDate else { return points }
        let cutoff = anchor.addingTimeInterval(-Double(days) * 86_400)
        return points.filter { $0.date >= cutoff }
    }

    private var visible: [PriceSeries] {
        series.map { PriceSeries(name: $0.name, points: clipped($0.points)) }
            .filter { !$0.points.isEmpty }
    }

    private func nearest(_ points: [PricePoint], to date: Date) -> PricePoint? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private struct Callout { let date: Date; let values: [(name: String, value: Double, color: Color)] }

    private var selection: Callout? {
        guard let selectedDate, let primary = visible.first,
              let anchor = nearest(primary.points, to: selectedDate) else { return nil }
        let values = visible.compactMap { s -> (String, Double, Color)? in
            guard let p = nearest(s.points, to: selectedDate) else { return nil }
            return (s.name, p.value, color(s.name))
        }
        return Callout(date: anchor.date, values: values)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsRangePicker {
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            chart.frame(height: 200)

            if visible.count > 1 {
                HStack(spacing: 14) {
                    ForEach(visible) { s in
                        HStack(spacing: 4) {
                            Circle().fill(color(s.name)).frame(width: 8, height: 8)
                            Text(s.name).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(visible) { s in
                if s.id == visible.first?.id {
                    ForEach(s.points) { p in
                        AreaMark(x: .value("Date", p.date), y: .value("USD", p.value))
                            .foregroundStyle(.linearGradient(
                                colors: [color(s.name).opacity(0.25), .clear],
                                startPoint: .top, endPoint: .bottom))
                    }
                }
                ForEach(s.points) { p in
                    LineMark(x: .value("Date", p.date), y: .value("USD", p.value))
                        .foregroundStyle(color(s.name))
                        .interpolationMethod(.monotone)
                }
            }
            if let selection {
                RuleMark(x: .value("Date", selection.date))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, alignment: .center,
                                overflowResolution: .init(x: .fit, y: .disabled)) {
                        callout(selection)
                    }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v, format: .currency(code: "USD").precision(.fractionLength(0)))
                    }
                }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
    }

    private func callout(_ sel: Callout) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sel.date, format: .dateTime.month().day().year())
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(sel.values, id: \.name) { v in
                HStack(spacing: 4) {
                    if sel.values.count > 1 { Circle().fill(v.color).frame(width: 6, height: 6) }
                    Text(v.value, format: .currency(code: "USD")).font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(6)
        // Solid adaptive background, not a material — materials inside chart annotations can
        // render without their backdrop blur (→ unreadable dark box over the plot).
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}
