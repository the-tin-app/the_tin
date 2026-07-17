import SwiftUI

/// Always-on, non-blocking support bar: shows progress toward the monthly funding goal and a
/// "Support" affordance that opens the donation page in Safari. Nothing in the app is gated by
/// funding, and donations are never processed in-app — that (external link + no unlocked content)
/// is what keeps this App Store-compliant. Keep the copy a general support ask; never imply a
/// donation unlocks a feature.
struct FundingBar: View {
    let funding: FundingDisplay
    @Environment(\.openURL) private var openURL
    // Collapsed by default: an always-on ask that stays out of the way (it previously ate the
    // top safe area and hid the search bar). Tap to expand; the choice persists per device.
    @AppStorage("fundingBarCollapsed") private var collapsed = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func setCollapsed(_ value: Bool) {
        if reduceMotion { collapsed = value } else { withAnimation(.snappy) { collapsed = value } }
    }

    private var fundedPctText: String { "\(Int((min(max(funding.fundedPct, 0), 1) * 100).rounded()))% funded" }

    var body: some View {
        Group {
            if collapsed { collapsedStrip } else { expanded }
        }
        .background(.thinMaterial)
    }

    private var collapsedStrip: some View {
        Button { setCollapsed(false) } label: {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption)
                Text("Support the project — \(fundedPctText)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var expanded: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Support the project — \(FundingModel.dollars(funding.raisedCents)) of \(FundingModel.dollars(funding.monthlyGoalCents))/mo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FundedMeter(fundedPct: funding.fundedPct)
            }
            Spacer(minLength: 8)
            Button("Support") { openURL(AppConfig.supportURL) }
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button { setCollapsed(true) } label: {
                Image(systemName: "chevron.up")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Collapse support bar")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

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
