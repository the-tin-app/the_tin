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

    /// Deliberately neutral, and deliberately NOT the funded percentage. This bar is always on
    /// screen in the app's chrome, and an app whose whole pitch is "no ads" cannot carry a
    /// permanent donation prompt there — Settings carries the actual ask. Expanding is an opt-in
    /// act, so the button lives one tap in. (It also can't say "0% funded" to every user on day
    /// one, which is the other half of why the old copy was wrong.)
    private var collapsedText: String { "Support the project" }

    var body: some View {
        Group {
            if collapsed { collapsedStrip } else { expanded }
        }
        // ⚠️ `ignoresSafeAreaEdges: []` — see `ReducedDataBanner` for why. This bar and the two
        // banners above it live in one top `safeAreaInset`, and whichever is topmost paints the
        // region behind iPadOS 26's floating tab bar unless it is told not to.
        .background(.thinMaterial, ignoresSafeAreaEdges: [])
    }

    private var collapsedStrip: some View {
        Button { setCollapsed(false) } label: {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) // contrast-ok: glyph, not text
                Text(collapsedText)
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
            if FundingModel.isLive {
                VStack(alignment: .leading, spacing: 4) {
                    // The meter is gated on money actually raised, NOT on `isLive` — see that
                    // flag's doc comment. At zero there is no bar to draw and "0% funded" would
                    // undersell the ask; the sentence carries it until the first sponsorship.
                    if funding.raisedCents > 0 {
                        Text("Support the project — \(FundingModel.dollars(funding.raisedCents)) of \(FundingModel.dollars(funding.monthlyGoalCents))/mo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        FundedMeter(fundedPct: funding.fundedPct)
                    } else {
                        Text("The Tin is free and nothing is ever locked. Sponsorship covers what it costs to run.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button("Support") { openURL(AppConfig.supportURL) }
                    .font(.caption.bold())
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Text("Community funding is almost ready. The Tin is free and nothing will ever be locked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
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
