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

    /// A LINK to the hunt, not the hunt itself.
    ///
    /// This section used to render the same `HuntRow`s as the Hunting segment of Wishlist — so one
    /// list existed twice, on two screens reached from two pinned rows stacked on top of each
    /// other, and `WatchingTip` existed to explain that Watching "isn't another list" while its
    /// first section was demonstrably the other list. Watching is the news; hunting is the doing.
    /// The row says how many and gets out of the way.
    @ViewBuilder private var huntingSection: some View {
        if !model.hunting.isEmpty {
            Section {
                NavigationLink(value: WantedRoute(scope: .hunting)) {
                    HStack(spacing: 10) {
                        Image(systemName: "binoculars").foregroundStyle(.tint)
                        Text("^[\(model.hunting.count) card](inflect: true) on the hunt")
                        Spacer()
                    }
                }
            } header: {
                Text("Hunting")
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
                    NavigationLink(value: CardID(raw: drop.card.id)) {
                        cardRow(card: drop.card, setName: drop.setName,
                                caption: drop.targetUsd.map {
                                    "You're watching for \($0.formatted(.currency(code: "USD").precision(.fractionLength(0))))"
                                } ?? "No target set",
                                marketUsd: drop.marketUsd) {
                            // Always a real drop here (past DiscoverConstants.dealsMaxPct7d),
                            // so this can never be the flat case.
                            Text(HuntRow.delta(drop.pct7d).text)
                                .font(.caption).foregroundStyle(Color.statusPositive)
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
                    NavigationLink(value: CardID(raw: grail.card.id)) {
                        cardRow(card: grail.card, setName: grail.setName,
                                caption: "Up \(grail.trend.upWeeks) of the last \(grail.trend.totalWeeks) weeks",
                                marketUsd: grail.marketUsd) {
                            Text(HuntRow.delta(grail.trend.pct).text)
                                .font(.caption)
                                .foregroundStyle(grail.trend.pct < 0 ? .green : .red)
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

    /// One identifiable card row, shared by drops and grails.
    ///
    /// ⚠️ The thumbnail and the `Set · number` line are not decoration. A wishlist can hold
    /// three cards called Charizard, and a row showing only the name makes you go and work out
    /// which one moved — which is exactly the errand this screen exists to save. Reported on
    /// device 2026-08-01; the original mockup had the set and number and the first
    /// implementation dropped them.
    @ViewBuilder
    private func cardRow<Trailing: View>(card: CardRecord, setName: String?, caption: String,
                                         marketUsd: Double?,
                                         @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CardImageView(card: card, quality: "low").frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name).font(.headline).lineLimit(1)
                Text([setName, "#\(card.number)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let marketUsd {
                    Text(marketUsd, format: .currency(code: "USD")).monospacedDigit()
                }
                trailing()
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
