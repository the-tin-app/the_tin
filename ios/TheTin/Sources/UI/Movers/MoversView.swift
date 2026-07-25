import SwiftUI

/// The Movers tab: what your tin did over the selected window, biggest dollar mover first.
///
/// Deliberately money-first rather than chart-first (`PRODUCT.md` anti-reference: finance-app
/// coldness) — the cards still carry the screen, the number just says why you're looking.
struct MoversView: View {
    @Bindable var model: CollectionModel
    let store: CatalogStore
    var wants: WantsModel? = nil
    /// The same app-wide key `DeltaBadge`/`DeltaPeriodPicker` read, so changing the window here
    /// changes every change badge in the app — one period, one meaning.
    @AppStorage("deltaPeriod") private var periodRaw: String = DeltaPeriod.d1.rawValue
    /// Your holdings, or the whole catalog. Persisted: which question you're asking tends to hold
    /// for a session ("what did my tin do" vs "what should I be chasing").
    @AppStorage("moversScope") private var scopeRaw: String = Scope.mine.rawValue
    /// Catalog movers for the current period; reloaded when the period changes, not per body pass.
    @State private var market: [Movers.MarketRow] = []

    enum Scope: String, CaseIterable {
        case mine, market
        var label: String { self == .mine ? "My Cards" : "Market" }
    }

    private var period: DeltaPeriod { DeltaPeriod(rawValue: periodRaw) ?? .d1 }
    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .mine }
    private var tier: CatalogTier { CatalogTier(rawValue: AppConfig.catalogTier) ?? .average }

    /// Cheap enough to compute in `body`: it's arithmetic over dictionaries `CollectionModel`
    /// already holds in memory — no SQLite reads, unlike the portfolio series.
    private var summary: Movers.Summary {
        Movers.summary(entries: model.entries, prices: model.prices,
                       deltasByCard: model.deltasByCard,
                       variantsByCard: model.variantsByCard,
                       conditionsByCard: model.conditionsByCard,
                       matrixByCard: model.matrixByCard,
                       gradedByPrintingByCard: model.gradedByPrintingByCard,
                       period: period)
    }

    var body: some View {
        let summary = summary
        List {
            Section {
                header(summary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            if scope == .mine, !summary.rows.isEmpty {
                Section {
                    ForEach(summary.rows) { row in
                        NavigationLink(value: CardID(raw: row.cardId)) {
                            MoverRow(row: row, card: try? store.card(id: row.cardId))
                        }
                    }
                } footer: {
                    coverageFooter(summary)
                }
            }
            if scope == .market, !market.isEmpty {
                Section {
                    ForEach(market) { row in
                        NavigationLink(value: CardID(raw: row.cardId)) {
                            MarketMoverRow(row: row, card: try? store.card(id: row.cardId),
                                           owned: ownedIds.contains(row.cardId),
                                           wanted: wants?.isWanted(row.cardId) ?? false)
                        }
                    }
                } footer: {
                    Text("Cards over \(Movers.marketFloorUsd, format: .currency(code: "USD").precision(.fractionLength(0))), by percent moved. Cheaper cards swing on rounding alone.")
                }
            }
        }
        .listStyle(.plain)
        .overlay { emptyState(summary) }
        .task(id: "\(periodRaw)|\(scopeRaw)|\(model.catalogGeneration)") { await loadMarket() }
        .navigationTitle("Movers")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: CardID.self) { cardID in
            if let card = try? store.card(id: cardID.raw) {
                CardDetailView(model: CardDetailModel(store: store, card: card,
                                                      history: CatalogPriceHistory(store: store)),
                               store: store, collection: model, wants: wants)
            }
        }
    }

    // MARK: pieces

    @ViewBuilder private func header(_ summary: Movers.Summary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Scope", selection: $scopeRaw) {
                ForEach(Scope.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            if scope == .mine {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(signed(summary.totalImpact))
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(tint(summary.totalImpact))
                    Text(period.label).font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Your tin is \(summary.totalImpact >= 0 ? "up" : "down") \(abs(summary.totalImpact).formatted(.currency(code: "USD"))) since \(period.label)")
            } else {
                // No total to headline: these aren't your cards, so there's no holding to sum.
                Text("Biggest movers \(period.label)")
                    .font(.headline)
            }
            DeltaPeriodPicker()
            if let asOf = model.priceAsOf { AsOfLabel(date: asOf) }
        }
    }

    private var ownedIds: Set<String> { Set(model.entries.map(\.cardId)) }

    private func loadMarket() async {
        guard scope == .market else { return }
        let store = self.store
        let period = self.period
        market = await Task.detached {
            (try? store.topMovers(period: period, minUsd: Movers.marketFloorUsd,
                                  limit: Movers.marketLimit)) ?? []
        }.value
    }

    @ViewBuilder private func coverageFooter(_ summary: Movers.Summary) -> some View {
        if summary.cardsWithData < summary.totalCards {
            Text("Based on \(summary.cardsWithData) of \(summary.totalCards) cards with price changes for this window.")
        }
    }

    @ViewBuilder private func emptyState(_ summary: Movers.Summary) -> some View {
        // `publish-tiers.ts` empties price_delta for the Small catalog, exactly as it does
        // price_history — so there is nothing to show and the honest reason is a download-size
        // one. Same words as the portfolio and price-history notices: never an upsell, and it
        // says "free" out loud (PRODUCT.md anti-reference).
        if tier == .casual {
            VStack(alignment: .leading, spacing: 6) {
                Label("Price changes aren't in the Small catalog", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.subheadline.weight(.medium))
                Text("Choose the Standard or Complete catalog in Settings to see what your cards — and the market — are doing. Every option is free.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .padding()
        } else if scope == .market {
            if market.isEmpty {
                ContentUnavailableView("Nothing moved \(period.label)", systemImage: "equal.circle",
                                       description: Text("No catalog price changes landed for this window. Try a longer one."))
            }
        } else if model.entries.isEmpty {
            ContentUnavailableView("Nothing in your tin yet", systemImage: "chart.line.uptrend.xyaxis",
                                   description: Text("Add a card and this is where you'll see what it does."))
        } else if summary.rows.isEmpty {
            ContentUnavailableView {
                Label("Nothing moved \(period.label)", systemImage: "equal.circle")
            } description: {
                Text(summary.cardsWithData == 0
                     ? "No price changes have landed for your cards in this window yet — try a longer one, or check back after the next catalog update."
                     : "Your cards held their value. Try a longer window.")
            }
        }
    }

    private func signed(_ v: Double) -> String {
        (v >= 0 ? "+" : "−") +
            abs(v).formatted(.currency(code: "USD").precision(.fractionLength(abs(v) < 1000 ? 2 : 0)))
    }

    private func tint(_ v: Double) -> Color {
        abs(v) < 0.005 ? .secondary : (v > 0 ? .green : .red)
    }
}

/// A card the market moved that you may not own — percent-first, since there's no holding to
/// value. Badged when it's already in your tin or on your wishlist, which is the whole point:
/// spotting a card you're hunting climbing before you buy it.
private struct MarketMoverRow: View {
    let row: Movers.MarketRow
    let card: CardRecord?
    let owned: Bool
    let wanted: Bool

    var body: some View {
        HStack(spacing: 12) {
            CardImageView(card: card, quality: "low").frame(width: 44)
                .overlay(alignment: .topTrailing) {
                    if owned || wanted { CardBadges(owned: owned, wanted: wanted).scaleEffect(0.85) }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(card?.name ?? row.cardId).lineLimit(1)
                Text(row.usd, format: .currency(code: "USD"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Text((row.pct > 0 ? "+" : "−") + abs(row.pct).formatted(.percent.precision(.fractionLength(1))))
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(row.pct > 0 ? .green : .red)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card?.name ?? row.cardId), \(row.usd.formatted(.currency(code: "USD"))), \(row.pct >= 0 ? "up" : "down") \(abs(row.pct).formatted(.percent.precision(.fractionLength(1))))\(wanted ? ", on your wishlist" : "")\(owned ? ", in your tin" : "")")
    }
}

/// One card's move: art, what you hold, and the dollars it put on (or took off) the tin.
private struct MoverRow: View {
    let row: Movers.Row
    let card: CardRecord?

    var body: some View {
        HStack(spacing: 12) {
            CardImageView(card: card, quality: "low").frame(width: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(card?.name ?? row.cardId).lineLimit(1)
                Text("×\(row.qty) · \(row.value.formatted(.currency(code: "USD")))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(signed(row.impact))
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(row.impact > 0 ? .green : .red)
                if let pct = row.pct {
                    Text(pct, format: .percent.precision(.fractionLength(1)))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let name = card?.name ?? row.cardId
        let direction = row.impact >= 0 ? "up" : "down"
        let amount = abs(row.impact).formatted(.currency(code: "USD"))
        return "\(name), \(row.qty) \(row.qty == 1 ? "copy" : "copies"), \(direction) \(amount)"
    }

    private func signed(_ v: Double) -> String {
        (v >= 0 ? "+" : "−") + abs(v).formatted(.currency(code: "USD"))
    }
}
