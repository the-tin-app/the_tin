import SwiftUI

/// Credits screen for sponsors who asked to be listed — the one benefit promised to the top
/// sponsorship tier.
///
/// Three things about this screen are deliberate and shouldn't be "improved" away:
/// - **Recognition only.** Nothing here unlocks anything. The moment sponsorship gates a feature,
///   Apple treats it as purchasable digital content and requires IAP.
/// - **Behind a tap.** Reachable only from Settings → Support, never from a feed or card view.
///   The app's whole pitch is "no ads"; a name in a scroll view makes that untrue.
/// - **Names are served, not compiled in.** Removing someone is a JSON edit on the NAS, not an
///   App Store review cycle. Anonymity is the default: absence from the served list *is* the
///   opt-out, so there is no flag to forget to set.
struct SupportersView: View {
    let supporters: [Supporter]

    var body: some View {
        List {
            Section {
                if supporters.isEmpty {
                    // Honest empty state — there are genuinely zero listed sponsors today, and a
                    // placeholder name would be a lie on a screen whose entire point is credit.
                    Text("No supporters listed yet.")
                        .foregroundStyle(.secondary)
                } else {
                    // Indices, not the model: two sponsors may legitimately share a display name.
                    // `tier` rides along in the served data for later grouping — see Supporter.
                    ForEach(supporters.indices, id: \.self) { i in
                        SupporterRow(supporter: supporters[i])
                    }
                }
            } header: {
                Text("Thank you")
            } footer: {
                Text(supporters.isEmpty
                     ? "Sponsors can choose to have their name shown here. Anyone who'd rather stay anonymous simply isn't listed."
                     : "Listed with permission. Sponsors who'd rather stay anonymous aren't shown here.")
            }

            if FundingModel.isLive {
                Section {
                    Link("Sponsor The Tin on GitHub", destination: AppConfig.supportURL)
                } footer: {
                    Text("Sponsorship covers running costs. It never unlocks features — The Tin is free either way.")
                }
            }
        }
        .navigationTitle("Supporters")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SupporterRow: View {
    let supporter: Supporter

    var body: some View {
        // `link` is nil unless the served URL is https — see Supporter.link.
        if let link = supporter.link {
            Link(destination: link) {
                HStack {
                    Text(supporter.name).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(supporter.name)
        }
    }
}
