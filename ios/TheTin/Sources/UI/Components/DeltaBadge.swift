import SwiftUI

/// Compact, display-only price-change badge: green/red arrow + % for the app-wide selected
/// period (@AppStorage "deltaPeriod", driven by `DeltaPeriodPicker`). Near-zero (<0.05%) shows a
/// gray dash; a record with data but none for the current window shows a muted dash (so the row
/// doesn't look empty); a nil/empty record shows nothing. Not interactive — the period is changed
/// via `DeltaPeriodPicker`, shown wherever these badges appear.
struct DeltaBadge: View {
    let record: DeltaRecord?
    @AppStorage("deltaPeriod") private var periodRaw: String = DeltaPeriod.d1.rawValue

    private var period: DeltaPeriod { DeltaPeriod(rawValue: periodRaw) ?? .d1 }

    var body: some View {
        if let record, record.hasData {
            if let pct = record.pct(for: period) {
                label(pct: pct).accessibilityLabel(accessibility(pct: pct))
            } else {
                noData.accessibilityLabel("no change data for \(period.label)")
            }
        }
    }

    /// Placeholder when this record has change data but not for the selected window — muted and
    /// distinct from the near-zero dash, so the row reads as "no data here", not "unchanged".
    private var noData: some View {
        Text("—")
            .font(.caption2.weight(.semibold)).monospacedDigit()
            .foregroundStyle(.tertiary)
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

/// App-wide period selector for the change badges — a compact segmented control bound to
/// @AppStorage "deltaPeriod". Changing it updates every `DeltaBadge` in the app at once. Placed
/// wherever badges are shown (the card-detail header, a divider's stats).
struct DeltaPeriodPicker: View {
    @AppStorage("deltaPeriod") private var periodRaw: String = DeltaPeriod.d1.rawValue

    var body: some View {
        Picker("Change vs", selection: $periodRaw) {
            ForEach(DeltaPeriod.allCases, id: \.rawValue) { period in
                Text(period.short).tag(period.rawValue)
            }
        }
        .pickerStyle(.segmented)
    }
}
