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

    private var period: DeltaPeriod { DeltaPeriod(rawValue: periodRaw) ?? .d1 }

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
            if !summary.rows.isEmpty {
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
        }
        .listStyle(.plain)
        .overlay { emptyState(summary) }
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

    private func header(_ summary: Movers.Summary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
            DeltaPeriodPicker()
            if let asOf = model.priceAsOf { AsOfLabel(date: asOf) }
        }
    }

    @ViewBuilder private func coverageFooter(_ summary: Movers.Summary) -> some View {
        if summary.cardsWithData < summary.totalCards {
            Text("Based on \(summary.cardsWithData) of \(summary.totalCards) cards with price changes for this window.")
        }
    }

    @ViewBuilder private func emptyState(_ summary: Movers.Summary) -> some View {
        if model.entries.isEmpty {
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
