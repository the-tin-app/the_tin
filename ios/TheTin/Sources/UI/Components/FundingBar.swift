import SwiftUI

/// A plain, non-interactive progress meter — no gesture recognizers, no tap targets.
struct FundedMeter: View {
    let fundedPct: Double

    private var clamped: Double { min(max(fundedPct, 0), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.25))
                    Capsule().fill(.secondary)
                        .frame(width: geo.size.width * clamped)
                }
            }
            .frame(height: 4)
            Text("\(Int((clamped * 100).rounded()))% funded")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
