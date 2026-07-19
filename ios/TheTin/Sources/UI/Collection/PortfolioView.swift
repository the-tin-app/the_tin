import SwiftUI

/// Navigation target for the tin header's total → Portfolio screen. `groupId` nil = whole tin
/// (matches `TinPagerRoute`/`GroupPagerView`'s convention); non-nil (incl. "") = one divider's
/// own trendline, tapped from that divider's landing chart (`GroupDetailView`).
struct PortfolioRoute: Hashable {
    var groupId: String? = nil
}

/// Value over time for the whole tin, or (when `groupId` is set) one divider: value + cost-basis
/// chart and stat row. The whole-tin view shows only the whole tin — per-divider performance
/// lives with each divider (2026-07-17 UX pass).
/// Casual tier ships `price_history` empty → download-size notice (same pattern as card detail).
/// Layout follows mockup variant B ("chart-hero"):
/// headline value+Δ on one line, dominant chart, stats demoted to a 3-up card row below the
/// chart, then the divider list.
struct PortfolioView: View {
    @Bindable var model: CollectionModel
    var groupId: String? = nil
    @State private var range: Range = .all

    /// nil = whole tin; "" = the ungrouped stack; anything else = that divider's own name.
    private var title: String {
        guard let groupId else { return "Portfolio" }
        return groupId.isEmpty ? "No divider" : (model.groups.first { $0.id == groupId }?.name ?? "Portfolio")
    }

    private var series: PortfolioSeries? {
        guard let groupId else { return model.portfolio.series }
        return model.portfolio.groupSeries[groupId]
    }

    /// Portfolio ranges are longer than card detail's (collections span years): 3M/6M/1Y/All.
    enum Range: String, CaseIterable, Identifiable {
        case m3 = "3M", m6 = "6M", y1 = "1Y", all = "All"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .m3: return 90
            case .m6: return 180
            case .y1: return 365
            case .all: return nil
            }
        }
    }

    private var tier: CatalogTier { CatalogTier(rawValue: AppConfig.catalogTier) ?? .average }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.entries) {
            await model.portfolio.refresh(entries: model.entries, prices: model.prices,
                                          variantsByCard: model.variantsByCard,
                                          conditionsByCard: model.conditionsByCard,
                                          matrixByCard: model.matrixByCard,
                                          gradedByPrintingByCard: model.gradedByPrintingByCard)
        }
    }

    @ViewBuilder private var content: some View {
        if tier == .casual {
            historyNotice
        } else if let series {
            if series.totalCards == 0 {
                Text(groupId == nil ? "Add cards to your tin to see its value over time."
                                    : "Add cards to this divider to see its value over time.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if series.cardsWithHistory == 0 {
                // Spec edge case: every card missing history — no chart, coverage note only.
                Label("None of your \(series.totalCards) cards have price history yet — check back after the next catalog update.",
                      systemImage: "chart.line.uptrend.xyaxis")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                headline(series)
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                PriceHistoryChart(series: chartSeries(series), showsRangePicker: false)
                statCardRow(series)
                if series.cardsWithHistory < series.totalCards {
                    Text("Based on \(series.cardsWithHistory) of \(series.totalCards) cards with price history.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else {
            ProgressView("Building portfolio history…").frame(maxWidth: .infinity)
        }
    }

    // MARK: pieces

    /// Points within the selected trailing range, anchored to the newest point (data can be stale).
    private func sliced(_ points: [PortfolioPoint]) -> [PortfolioPoint] {
        guard let days = range.days, let last = points.last else { return points }
        let cutoff = last.date.addingTimeInterval(-Double(days) * 86_400)
        return points.filter { $0.date >= cutoff }
    }

    /// Value (area-filled primary) + Cost basis (gray overlay, omitted when nobody entered paid prices).
    private func chartSeries(_ series: PortfolioSeries) -> [PriceSeries] {
        let pts = sliced(series.points)
        var out = [PriceSeries(name: "Value", points: pts.map { PricePoint(date: $0.date, value: $0.value) })]
        if (pts.last?.costBasis ?? 0) > 0 {
            out.append(PriceSeries(name: "Cost basis",
                                   points: pts.map { PricePoint(date: $0.date, value: $0.costBasis) }))
        }
        return out
    }

    /// Variant B headline: big value + range delta on one line (stat row demoted below the chart).
    private func headline(_ series: PortfolioSeries) -> some View {
        let pts = sliced(series.points)
        let now = pts.last?.value ?? 0
        let start = pts.first?.value ?? 0
        let delta = now - start
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(now, format: .currency(code: "USD").precision(.fractionLength(now < 1000 ? 2 : 0)))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(signed(delta) + (start > 0 ? String(format: " (%+.1f%%)", delta / start * 100) : ""))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(delta >= 0 ? .green : .red)
            }
            if let asOf = model.priceAsOf { AsOfLabel(date: asOf) }
        }
    }

    /// Variant B's 3-up card row below the chart: what you paid, change vs. paid, coverage.
    private func statCardRow(_ series: PortfolioSeries) -> some View {
        let pts = sliced(series.points)
        let now = pts.last?.value ?? 0
        let basis = pts.last?.costBasis ?? 0
        return HStack(spacing: 8) {
            if basis > 0 {
                statCard(label: "You paid", value: basis.formatted(.currency(code: "USD")), tint: .secondary)
                statCard(label: "Change vs. paid", value: signed(now - basis),
                         tint: now - basis >= 0 ? .green : .red)
            }
            statCard(label: "Coverage", value: "\(series.cardsWithHistory) / \(series.totalCards)", tint: .primary)
        }
    }

    private func signed(_ v: Double) -> String {
        (v >= 0 ? "+" : "−") +
            abs(v).formatted(.currency(code: "USD").precision(.fractionLength(abs(v) < 1000 ? 2 : 0)))
    }

    private func statCard(label: String, value: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Same visual pattern as CardDetailView's history notice. Copy rule: this is a
    /// download-size fact, never an upsell — say "free" out loud (PRODUCT.md anti-reference).
    private var historyNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Price history isn't in the Small catalog", systemImage: "chart.line.uptrend.xyaxis")
                .font(.subheadline.weight(.medium))
            Text("Choose the Standard or Complete catalog in Settings to chart your collection's value over time. Every option is free.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
