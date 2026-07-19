import SwiftUI
import Charts
import Observation

@MainActor @Observable
final class CardDetailModel {
    enum HistoryState: Equatable {
        case loading
        case loaded([PriceSeries])   // [0] = raw (primary); extras are expert overlays
        case empty
        case unavailable
    }

    let card: CardRecord
    private(set) var setName: String?
    private(set) var year: String?
    private(set) var price: PriceRecord?
    private(set) var conditions: [ConditionPrice] = []
    private(set) var variants: [VariantPrice] = []
    private(set) var matrix: [MatrixPrice] = []
    private(set) var gradedByPrinting: [GradedPrintingPrice] = []
    private(set) var population: [PopulationRow] = []
    private(set) var deltas: [DeltaRecord] = []
    private(set) var historyState: HistoryState = .loading
    /// The active catalog tier — drives how much price history the chart shows and its empty copy.
    let tier: CatalogTier
    /// Expert-tier chart overlays: which condition / PSA grade to chart alongside raw. `nil` = off.
    /// The view re-runs `loadHistory()` when either changes (`.task(id:)`). Menus offer ONLY
    /// dimensions this card has history rows for — a menu of options that plot nothing reads
    /// as broken (2026-07-18 report). Graded history is empty in production until PPT ships
    /// dated series, so the PSA menu is currently hidden for every card.
    private(set) var availableConditions: [Condition] = []
    private(set) var availableGrades: [Grade] = []
    var overlayCondition: Condition?
    var overlayGrade: Grade?
    private let store: CatalogStore
    private let history: PriceHistoryProviding

    init(store: CatalogStore, card: CardRecord, history: PriceHistoryProviding) {
        self.card = card
        self.store = store
        self.history = history
        self.tier = CatalogTier(rawValue: AppConfig.catalogTier) ?? .average
        price = try? store.price(cardId: card.id)
        conditions = (try? store.conditionPrices(cardId: card.id)) ?? []
        variants = (try? store.variantPrices(cardId: card.id)) ?? []
        matrix = (try? store.matrixPrices(cardId: card.id)) ?? []
        gradedByPrinting = (try? store.gradedPrintingPrices(cardId: card.id)) ?? []
        population = (try? store.population(cardId: card.id)) ?? []
        deltas = (try? store.deltas(cardId: card.id)) ?? []
        if tier == .expert {
            availableConditions = (try? store.availableConditions(cardId: card.id)) ?? []
            availableGrades = (try? store.availableGrades(cardId: card.id)) ?? []
        }
        overlayCondition = availableConditions.contains(.nearMint) ? .nearMint : nil
        overlayGrade = availableGrades.first   // highest available grade, or nil
        if let set = try? store.set(id: card.setId) {
            setName = set.name
            if let date = set.releaseDate, date.count >= 4 { year = String(date.prefix(4)) }
        }
    }

    func delta(_ kind: DeltaRecord.Kind, _ key: String = "") -> DeltaRecord? {
        deltas.first { $0.kind == kind && $0.key == key }
    }

    func loadHistory() async {
        do {
            let raw = try await history.rawHistory(cardId: card.id)
            guard !raw.isEmpty else { historyState = .empty; return }
            var series = [PriceSeries(name: "Raw", points: raw)]
            // Expert tier only: overlay the selected condition / PSA grade history. Those tables
            // are dropped below expert, so the queries only run here — never on casual/average.
            if tier == .expert {
                if let cond = overlayCondition,
                   let pts = try? store.conditionHistory(cardId: card.id, condition: cond), !pts.isEmpty {
                    series.append(PriceSeries(name: cond.label, points: pts))
                }
                if let grade = overlayGrade,
                   let pts = try? store.gradedHistory(cardId: card.id, grade: String(grade.numeric)), !pts.isEmpty {
                    series.append(PriceSeries(name: grade.label, points: pts))
                }
            }
            historyState = .loaded(series)
        } catch {
            historyState = .unavailable
        }
    }
}

struct CardDetailView: View {
    @Bindable var model: CardDetailModel
    let store: CatalogStore
    var collection: CollectionModel? = nil
    var wants: WantsModel? = nil
    @State private var showingAddSheet = false
    @State private var selectedPrinting: String?
    @State private var gradingFee: Double = AppConfig.gradingFeeUsd
    @FocusState private var gradingFeeFocused: Bool
    @State private var marketplaceURL: MarketplaceURL?
    @AppStorage("deltaPeriod") private var deltaPeriodRaw: String = DeltaPeriod.d1.rawValue

    /// Identifiable wrapper so `.sheet(item:)` can present a plain URL.
    private struct MarketplaceURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private static let priceColumns = [GridItem(.adaptive(minimum: 88), spacing: 8)]

    /// The printing the price header is scoped to, when the card has more than one priced
    /// printing. Defaults to the finish the rarity heuristic says this card is, else the cheapest.
    private var currentPrinting: VariantPrice? {
        guard model.variants.count > 1 else { return nil }
        if let selectedPrinting, let v = model.variants.first(where: { $0.printing == selectedPrinting }) {
            return v
        }
        let def = CardVariant.defaultFor(rarity: model.card.rarity)
        return model.variants.first { def.matches(printing: $0.printing) } ?? model.variants.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardImageView(card: model.card, quality: "high")
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.card.name).font(.title2.bold())
                    if let setName = model.setName {
                        Text(model.year.map { "\(setName) · \($0)" } ?? setName)
                            .font(.subheadline.weight(.medium))
                    }
                    Text("#\(model.card.number) · \(model.card.rarity ?? "—") · \(model.card.artist ?? "Unknown artist")")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let hp = model.card.hp { Text("HP \(hp)").font(.subheadline).foregroundStyle(.secondary) }
                }

                if let price = model.price {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("Prices").font(.headline); Spacer(); AsOfLabel(date: price.asOf) }
                        // Multi-printing cards get a dropdown; the headline price is scoped to it.
                        if model.variants.count > 1 {
                            Menu {
                                ForEach(model.variants) { v in
                                    Button {
                                        selectedPrinting = v.printing
                                    } label: {
                                        if v.printing == currentPrinting?.printing {
                                            Label("\(v.printing) · \(v.usd.formatted(.currency(code: "USD")))",
                                                  systemImage: "checkmark")
                                        } else {
                                            Text("\(v.printing) · \(v.usd.formatted(.currency(code: "USD")))")
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(currentPrinting?.printing ?? "Printing")
                                        .font(.subheadline.weight(.semibold))
                                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.quaternary.opacity(0.4), in: Capsule())
                            }
                            .tint(.primary)
                        }
                        // Headline number: the selected printing's market price when the card has
                        // multiple printings; else raw market, else the NM condition price
                        // (a separate feed — raw can be null while NM has a value; NM ≈ raw market).
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let printing = currentPrinting {
                                Text(printing.usd, format: .currency(code: "USD"))
                                    .font(.system(.title, design: .rounded).weight(.bold))
                                    .monospacedDigit()
                                Text("\(printing.printing) · market").font(.caption).foregroundStyle(.secondary)
                                DeltaBadge(record: model.delta(.printing, printing.printing))
                            } else if let raw = price.rawUsd {
                                Text(raw, format: .currency(code: "USD"))
                                    .font(.system(.title, design: .rounded).weight(.bold))
                                    .monospacedDigit()
                                Text("raw market").font(.caption).foregroundStyle(.secondary)
                                DeltaBadge(record: model.delta(.raw))
                            } else if let nm = model.conditions.first(where: { $0.condition == .nearMint })?.usd {
                                Text(nm, format: .currency(code: "USD"))
                                    .font(.system(.title, design: .rounded).weight(.bold))
                                    .monospacedDigit()
                                Text("NM · near mint market").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("No raw price").font(.title3).foregroundStyle(.secondary)
                                Text("raw market").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if model.deltas.contains(where: { $0.pct(for: DeltaPeriod(rawValue: deltaPeriodRaw) ?? .d1) != nil }) {
                            Text("Change vs \((DeltaPeriod(rawValue: deltaPeriodRaw) ?? .d1).label) — tap any badge to switch")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        // Printing-scoped slices — empty when the card has one printing, or when
                        // the selected printing has no matrix/graded rows (PPT gap-fill varies).
                        let printingMatrix = currentPrinting.map { p in model.matrix.filter { $0.printing == p.printing } } ?? []
                        let printingGraded = currentPrinting.map { p in model.gradedByPrinting.filter { $0.printing == p.printing } } ?? []
                        // Graded (PSA) prices — only grades with data appear. When the selected
                        // printing has its own graded row for a grade, that value replaces the
                        // card-level one; otherwise the card-level value is shown as a fallback.
                        let graded = Grade.allCases.filter { price.gradedOnly($0) != nil }
                        if !graded.isEmpty {
                            Text("Graded (PSA)").font(.subheadline.bold())
                            LazyVGrid(columns: Self.priceColumns, spacing: 8) {
                                ForEach(graded) { grade in
                                    let perPrinting = printingGraded.first { $0.grade == grade.rawValue }?.usd
                                    PriceTile(label: grade.label, value: perPrinting ?? price.gradedOnly(grade),
                                              delta: model.delta(.psa, String(grade.numeric)))
                                }
                            }
                            if currentPrinting != nil, printingGraded.isEmpty {
                                Text("Shown for the card overall — no \(currentPrinting!.printing)-specific graded sales.")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        // Ungraded per-condition prices (NM/LP/MP/HP/DMG). When the selected
                        // printing has matrix rows, tiles show that printing's own condition
                        // prices (with matrix deltas); otherwise fall back to card-level tiles.
                        if !model.conditions.isEmpty || !printingMatrix.isEmpty {
                            Text("By condition").font(.subheadline.bold())
                            if let p = currentPrinting, !printingMatrix.isEmpty {
                                LazyVGrid(columns: Self.priceColumns, spacing: 8) {
                                    ForEach(Condition.allCases.compactMap { c in printingMatrix.first { $0.condition == c } }) { cell in
                                        PriceTile(label: cell.condition.label, value: cell.usd,
                                                  delta: model.delta(.matrix, "\(p.printing)|\(cell.condition.rawValue)")
                                                      ?? model.delta(.condition, cell.condition.rawValue))
                                    }
                                }
                            } else {
                                LazyVGrid(columns: Self.priceColumns, spacing: 8) {
                                    ForEach(model.conditions) { cp in
                                        PriceTile(label: cp.condition.label, value: cp.usd,
                                                  delta: model.delta(.condition, cp.condition.rawValue))
                                    }
                                }
                                if currentPrinting != nil, !model.conditions.isEmpty {
                                    Text("Shown for the card overall — no \(currentPrinting!.printing)-specific condition prices.")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } else {
                    Text("No sales data for this card").font(.subheadline).foregroundStyle(.secondary)
                }

                priceHistorySection

                // "Grade it?" — grading-ROI verdict beside the population section. Hidden when
                // compute() returns nil (no PSA rows, no graded prices, or no baseline).
                if let roi = gradingROI {
                    gradeItSection(roi)
                }

                // PSA population — collapsed by default at the bottom; most people don't dig into
                // grade distributions. The "N graded · X% gem" summary stays on the collapsed row.
                if !model.population.isEmpty {
                    DisclosureGroup {
                        let maxCount = max(model.population.map(\.count).max() ?? 1, 1)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.population) { row in
                                PopulationBar(grade: row.displayGrade, count: row.count, maxCount: maxCount)
                            }
                            if currentPrinting != nil {
                                Text("Population counts are for the card overall — graders don't split printings here.")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: 8) {
                            Text("PSA Population").font(.headline)
                            if let total = model.population.first?.totalPopulation {
                                Text("\(total) graded").font(.caption).foregroundStyle(.secondary)
                            }
                            if let gem = model.population.first?.gemRate {
                                Text("· \(gem, format: .percent.precision(.fractionLength(0))) gem")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.secondary)
                }

                marketplaceSection
            }
            .padding()
        }
        .navigationTitle(model.card.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(model.overlayCondition?.rawValue ?? "-")|\(model.overlayGrade?.rawValue ?? "-")") {
            await model.loadHistory()
        }
        .toolbar { detailToolbar }
        .sheet(item: $marketplaceURL) { SafariSheet(url: $0.url) }
        .sheet(isPresented: $showingAddSheet) {
            if let collection {
                NavigationStack {
                    EntryFormView(card: model.card, groups: collection.groups, existing: nil,
                                  variants: model.variants, conditions: model.conditions,
                                  matrix: collection.matrixByCard[model.card.id] ?? [],
                                  onCreateGroup: { await collection.createGroup(name: $0) }) { entry in
                        await collection.saveEntry(entry)
                    }
                }
            }
        }
    }

    // Broken out of `body` — combined with the rest of the modifier chain it pushed the type
    // checker over its time budget ("unable to type-check this expression in reasonable time").
    @ToolbarContentBuilder private var detailToolbar: some ToolbarContent {
        if let wants {
            ToolbarItem {
                Button { wants.toggle(model.card.id) } label: {
                    Image(systemName: wants.isWanted(model.card.id) ? "heart.fill" : "heart")
                }
                .accessibilityLabel(wants.isWanted(model.card.id)
                                    ? "Remove from wishlist" : "Add to wishlist")
            }
        }
        if collection != nil {
            ToolbarItem {
                Button { showingAddSheet = true } label: { Image(systemName: "plus.square.on.square") }
                    .accessibilityLabel("Save to collection")
            }
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { gradingFeeFocused = false }
        }
    }

    /// Price-history area of the detail screen. Loaded → interactive chart. Empty on the casual
    /// tier → a download-size notice (history is intentionally stripped there; copy must never
    /// read as an upsell — everything is free); empty otherwise → "not enough history yet".
    /// Unavailable → offline/error.
    @ViewBuilder private var priceHistorySection: some View {
        switch model.historyState {
        case .loading:
            ProgressView("Loading price history…")
        case .loaded(let series):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Price history").font(.headline)
                    Spacer()
                    if model.tier == .expert { overlayPickers }
                }
                PriceHistoryChart(series: series)
                if currentPrinting != nil {
                    Text("History is for the card overall — PPT has no per-printing history.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        case .empty where model.tier == .casual:
            VStack(alignment: .leading, spacing: 6) {
                Label("Price history isn't in the Small catalog", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.subheadline.weight(.medium))
                Text("Choose the Standard or Complete catalog in Settings to see this card's price graph. Every option is free.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        case .empty:
            Label("Not enough price history yet — check back soon", systemImage: "clock")
                .font(.footnote).foregroundStyle(.secondary)
        case .unavailable:
            Label("No price history yet", systemImage: "chart.line.uptrend.xyaxis")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Expert-tier overlay selectors: one condition + one PSA grade (each can be off). Chips
    /// mirror the printing menu; dot color matches the chart line for that overlay. Each menu
    /// only appears when this card actually has history for that dimension, and only offers
    /// the values with rows — an option that plots nothing reads as broken.
    @ViewBuilder private var overlayPickers: some View {
        HStack(spacing: 6) {
            if !model.availableConditions.isEmpty {
                Menu {
                    Picker("Condition", selection: $model.overlayCondition) {
                        Text("Off").tag(Condition?.none)
                        ForEach(model.availableConditions) { Text($0.label).tag(Condition?.some($0)) }
                    }
                } label: {
                    overlayChip(model.overlayCondition?.label ?? "Condition",
                                dot: model.overlayCondition != nil ? .teal : nil)
                }
            }
            if !model.availableGrades.isEmpty {
                Menu {
                    Picker("PSA grade", selection: $model.overlayGrade) {
                        Text("Off").tag(Grade?.none)
                        ForEach(model.availableGrades) { Text($0.label).tag(Grade?.some($0)) }
                    }
                } label: {
                    overlayChip(model.overlayGrade?.label ?? "PSA",
                                dot: model.overlayGrade != nil ? .orange : nil)
                }
            }
        }
        .tint(.primary)
    }

    private func overlayChip(_ title: String, dot: Color?) -> some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(title).font(.caption.weight(.semibold))
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary.opacity(0.4), in: Capsule())
    }

    /// The user's first raw (ungraded) copy of this card. Its condition drives the baseline and
    /// the played-cards warning; graded copies are skipped — they're already graded.
    private var ownedRawEntry: CollectionEntry? {
        collection?.entries.first { $0.cardId == model.card.id && $0.grade == nil }
    }

    /// Baseline = what this copy sells for raw: the owned copy's unit value when owned
    /// (entryValue multiplies by qty, so price a qty-1 copy), else NM market, else raw market.
    private var gradingROI: GradingROI? {
        guard let price = model.price else { return nil }
        let baseline: Double?
        if let entry = ownedRawEntry {
            var one = entry
            one.qty = 1
            baseline = GroupStats.entryValue(one, price: price, variants: model.variants,
                                             conditions: model.conditions,
                                             matrix: model.matrix,
                                             gradedByPrinting: model.gradedByPrinting)
        } else {
            baseline = model.conditions.first(where: { $0.condition == .nearMint })?.usd ?? price.rawUsd
        }
        return GradingROI.compute(population: model.population, price: price, baseline: baseline,
                                  fee: gradingFee, ownedCondition: ownedRawEntry?.conditionValue)
    }

    /// One display row of the Grade It math. Grades ≤5 collapse into a single "PSA ≤5" row
    /// (their combined odds are usually tiny); `price` for the tail is the mass-weighted mean
    /// so probability × price still equals the summed EV contribution.
    private struct GradeRow: Identifiable {
        let label: String
        let probability: Double
        let price: Double
        let value: Double
        let isEstimate: Bool
        var id: String { label }
    }

    private static func gradeRows(_ roi: GradingROI) -> [GradeRow] {
        func row(_ b: GradingROI.Bucket) -> GradeRow {
            GradeRow(label: b.grade.label, probability: b.probability, price: b.price,
                     value: b.probability * b.price, isEstimate: b.isEstimate)
        }
        let head = roi.buckets.filter { $0.grade.numeric > 5 }
        let tail = roi.buckets.filter { $0.grade.numeric <= 5 }
        guard tail.count >= 2 else { return (head + tail).map(row) }
        let p = tail.reduce(0) { $0 + $1.probability }
        let v = tail.reduce(0) { $0 + $1.probability * $1.price }
        return head.map(row) + [GradeRow(label: "PSA ≤5", probability: p, price: p > 0 ? v / p : 0,
                                         value: v, isEstimate: tail.contains(where: \.isEstimate))]
    }

    /// Marketplace links (approved mockup variant A): disclosure rows below PSA Population,
    /// each opening an in-app Safari sheet. Plain URLs — no affiliate params.
    private var marketplaceSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) {
                marketplaceRow("eBay — current listings", systemImage: "cart",
                               url: MarketplaceLinks.ebayCurrent(name: model.card.name,
                                                                setName: model.setName,
                                                                number: model.card.number))
                Divider()
                marketplaceRow("eBay — sold listings", systemImage: "checkmark.seal",
                               url: MarketplaceLinks.ebaySold(name: model.card.name,
                                                             setName: model.setName,
                                                             number: model.card.number))
                Divider()
                marketplaceRow("TCGPlayer — card page", systemImage: "tag",
                               url: MarketplaceLinks.tcgplayer(tcgplayerId: model.card.tcgplayerId,
                                                              name: model.card.name,
                                                              number: model.card.number))
                Text("Opens in-app. Searches use card name, set, and number.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            .padding(.top, 6)
        } label: {
            Text("Shop & sold prices").font(.headline)
        }
        .tint(.secondary)
    }

    private func marketplaceRow(_ title: String, systemImage: String, url: URL) -> some View {
        Button { marketplaceURL = MarketplaceURL(url: url) } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                Text(title).font(.subheadline)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func verdictHeadline(_ roi: GradingROI) -> String {
        let amount = abs(roi.evNet).formatted(.currency(code: "USD").precision(.fractionLength(0)))
        switch roi.verdict {
        case .grade:      return "Worth grading — expected +\(amount) after fees"
        case .borderline: return "Borderline — about break-even after fees"
        case .keep:       return "Keep it raw — expected −\(amount) after fees"
        }
    }

    @ViewBuilder private func gradeItSection(_ roi: GradingROI) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(verdictHeadline(roi))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(roi.verdict == .grade ? AnyShapeStyle(.green)
                                                           : AnyShapeStyle(.primary))
                    .padding(.top, 6)
                // Expected-value math: per-grade odds × PSA price. "≈" marks interpolated
                // prices (mockup variant A: tilde + single amber footnote; grades ≤5 collapse
                // into one tail row so thin low-grade pop doesn't become six noise rows).
                ForEach(Self.gradeRows(roi)) { row in
                    HStack {
                        Text(row.label)
                            .font(.subheadline.monospacedDigit())
                            .frame(width: 68, alignment: .leading)
                        Text("\(row.probability, format: .percent.precision(.fractionLength(0))) × \(row.isEstimate ? "≈" : "")\(row.price, format: .currency(code: "USD"))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(row.isEstimate ? "≈" : "")\(row.value, format: .currency(code: "USD"))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(row.isEstimate ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    }
                }
                HStack {
                    Text("Expected graded value").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(roi.hasEstimates ? "≈" : "")\(roi.ev, format: .currency(code: "USD"))")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                }
                if roi.hasEstimates {
                    Text("≈ estimated from nearby grades — no recorded sales at that grade.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if let gem = roi.gemRate {
                    HStack {
                        Text("Gem rate").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(gem, format: .percent.precision(.fractionLength(0))).font(.caption)
                    }
                }
                HStack {
                    Text("Breakeven").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(roi.breakevenGrade.map { "needs a \($0.label) or better to beat raw" }
                         ?? "no grade beats selling raw")
                        .font(.caption)
                }
                HStack {
                    Text("Assumed grading fee").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    TextField("Fee", value: $gradingFee, format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.caption.monospacedDigit())
                        .frame(width: 90)
                        .focused($gradingFeeFocused)
                        .onChange(of: gradingFee) { _, newValue in
                            AppConfig.gradingFeeUsd = newValue   // clamped $0–$500 by the setter
                        }
                }
                if roi.playedWarning {
                    Text("Your copy is moderately played or worse — played cards rarely gem.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Text("Estimate only — not what this specific copy will cost. Once you grade it, record the actual fee on the entry for accurate cost-basis and insurance reports.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text("Odds use the full PSA population (\(roi.totalPopulation) graded) — copies people chose to grade; your card's odds depend on its condition.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        } label: {
            HStack(spacing: 8) {
                Text("Grade it?").font(.headline)
                if roi.lowConfidence {
                    Text("low data")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.yellow.opacity(0.25), in: Capsule())
                }
            }
        }
        .tint(.secondary)
    }
}

/// One PSA grade as a proportional bar (width relative to the most-populated grade), so the
/// population reads as a distribution at a glance instead of a long table of raw counts.
private struct PopulationBar: View {
    let grade: String
    let count: Int
    let maxCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("PSA \(grade)")
                .font(.subheadline.monospacedDigit())
                .frame(width: 68, alignment: .leading)
            GeometryReader { geo in
                Capsule().fill(.tint)
                    .frame(width: max(geo.size.width * CGFloat(count) / CGFloat(maxCount), 3))
            }
            .frame(height: 10)
            Text("\(count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

/// A compact price cell: label above the value, laid out in a grid so grade/condition prices
/// read as a scannable set of tiles rather than a long vertical list.
private struct PriceTile: View {
    let label: String
    let value: Double?
    var delta: DeltaRecord? = nil

    var body: some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            if let value {
                Text(value, format: .currency(code: "USD"))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            } else {
                Text("—").font(.subheadline).foregroundStyle(.secondary)
            }
            DeltaBadge(record: delta)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
