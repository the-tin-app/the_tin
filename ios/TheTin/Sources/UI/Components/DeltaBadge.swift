import SwiftUI

/// Compact price-change badge: green/red arrow + % for the app-wide selected period
/// (@AppStorage "deltaPeriod"). Near-zero (<0.05%) renders a gray dash; no data renders
/// nothing at all. Tapping anywhere cycles yesterday → week → month for every badge in
/// the app (the selection persists).
struct DeltaBadge: View {
    let record: DeltaRecord?
    @AppStorage("deltaPeriod") private var periodRaw: String = DeltaPeriod.d1.rawValue

    private var period: DeltaPeriod { DeltaPeriod(rawValue: periodRaw) ?? .d1 }

    var body: some View {
        if let pct = record?.pct(for: period) {
            Button { periodRaw = period.next.rawValue } label: {
                label(pct: pct)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibility(pct: pct))
        }
    }

    private func label(pct: Double) -> some View {
        HStack(spacing: 2) {
            if abs(pct) < 0.0005 {
                Text("–")
            } else {
                Image(systemName: pct > 0 ? "arrow.up" : "arrow.down")
                Text(abs(pct), format: .percent.precision(.fractionLength(1)))
            }
        }
        .font(.caption2.weight(.semibold)).monospacedDigit()
        .foregroundStyle(abs(pct) < 0.0005 ? AnyShapeStyle(.secondary)
                         : pct > 0 ? AnyShapeStyle(.green) : AnyShapeStyle(.red))
    }

    private func accessibility(pct: Double) -> String {
        if abs(pct) < 0.0005 { return "unchanged since \(period.label)" }
        let amount = abs(pct).formatted(.percent.precision(.fractionLength(1)))
        return "\(pct > 0 ? "up" : "down") \(amount) since \(period.label)"
    }
}
