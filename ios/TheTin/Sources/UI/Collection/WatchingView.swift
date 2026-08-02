import SwiftUI

/// What you said you care about, and what it has been doing. Hunting leads because it is what
/// you are actually buying; everything under it is information, not a prompt.
///
/// ⚠️ On the **casual** tier — which is every simulator, because App Attest can't run there —
/// `price_history` and `price_delta` are empty, so only the hunting section renders. That is the
/// honest degradation and it is deliberate: a section drawing a flat line would read as a real
/// trend. The footer says so in words, because a short screen otherwise reads as "nothing moved",
/// which is a different and false claim.
struct WatchingView: View {
    let store: CatalogStore
    let wants: WantsModel
    @State private var model = WatchingModel()

    var body: some View {
        List {
            if model.loaded && isEmpty { empty }
            huntingSection
            tinSection
            dropsSection
            grailsSection
            freshnessFooter
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Watching")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(store: store, wants: wants) }
        // Visiting IS what clears the dot, so this writes on the way in, not on the way out.
        .onChange(of: model.asOf) { _, asOf in
            if let asOf { AppConfig.watchingLastSeenAsOf = asOf }
        }
    }

    /// "No section will draw." ⚠️ This must mirror the section conditions EXACTLY, including
    /// `tin?.delta7d` rather than `tin` — a widget snapshot exists on the casual tier but carries
    /// no `delta7d`, so `tin != nil` reported "not empty" while every section still declined to
    /// draw, and the screen rendered as a bare footer with no heading. Caught on the simulator,
    /// not by a test, because the disagreement is between two view conditions.
    private var isEmpty: Bool {
        model.hunting.isEmpty && model.drops.isEmpty && model.grails.isEmpty
            && model.tin?.delta7d == nil
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing to watch yet", systemImage: "binoculars")
        } description: {
            Text("Switch on Hunting for a card you're buying, mark one a Grail, or set a price target — and what they do next shows up here.")
        }
        .listRowSeparator(.hidden)
    }

    // MARK: Sections

    @ViewBuilder private var huntingSection: some View {
        if !model.hunting.isEmpty {
            Section {
                ForEach(model.hunting) { item in
                    HuntRow(card: item.card, entry: item.entry, setName: item.setName,
                            printedTotal: item.printedTotal, marketUsd: item.marketUsd,
                            delta7d: item.delta7d)
                }
            } header: {
                Text("Hunting")
            } footer: {
                // ⚠️ "once a day" is load-bearing and verified: eBay's saved-search alert is a
                // daily email, there is no faster free route, and no copy may imply otherwise.
                Text("Save the search in eBay and it'll keep an eye out — eBay emails once a day.")
            }
        }
    }

    /// `delta7d == nil` means no history coverage, so say nothing rather than draw a flat week.
    @ViewBuilder private var tinSection: some View {
        if let tin = model.tin, let delta = tin.delta7d {
            Section("Your tin this week") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tin.totalValue, format: WidgetShared.tinCurrency(tin.totalValue))
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    Text("^[\(tin.cardCount) card](inflect: true) · \(delta < 0 ? "down" : "up") \(abs(delta), format: .currency(code: "USD").precision(.fractionLength(0))) this week")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var dropsSection: some View {
        if !model.drops.isEmpty {
            Section("Wishlist — biggest drops") {
                ForEach(model.drops) { drop in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(drop.card.name).font(.headline).lineLimit(1)
                            Text(drop.targetUsd.map {
                                "You're watching for \($0.formatted(.currency(code: "USD").precision(.fractionLength(0))))"
                            } ?? "No target set")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if let usd = drop.marketUsd {
                                Text(usd, format: .currency(code: "USD")).monospacedDigit()
                            }
                            Text(HuntRow.deltaLabel(drop.pct7d))
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var grailsSection: some View {
        if !model.grails.isEmpty {
            Section {
                ForEach(model.grails) { grail in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(grail.card.name).font(.headline).lineLimit(1)
                            Text("Up \(grail.trend.upWeeks) of the last \(grail.trend.totalWeeks) weeks")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let usd = grail.marketUsd {
                            Text(usd, format: .currency(code: "USD")).monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Your grails")
            } footer: {
                Text("Two years of weekly history — the long view, not this week's noise.")
            }
        }
    }

    /// Prices always carry their as-of stamp (Caption Ledger Rule), and when the three
    /// history-backed sections are dark the screen says WHY rather than just being short.
    @ViewBuilder private var freshnessFooter: some View {
        // Shown even when empty: on the casual tier "nothing to watch yet" is only half the
        // story, and the missing-history line is the other half.
        if model.loaded {
            VStack(alignment: .leading, spacing: 6) {
                if let asOf = model.asOf { AsOfLabel(date: asOf) }
                if historyMissing {
                    Text("Weekly movement, wishlist drops and grail trends need price history, which isn't in the card data on this device. Hunting only needs today's price.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .listRowSeparator(.hidden)
        }
    }

    /// True on the casual tier: no delta rows and no history rows, so three sections are empty
    /// for a reason that is not "the market was quiet".
    private var historyMissing: Bool {
        model.tin?.delta7d == nil && model.drops.isEmpty && model.grails.isEmpty
    }
}
