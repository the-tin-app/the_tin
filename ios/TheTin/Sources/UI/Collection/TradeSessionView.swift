import SwiftUI

/// Where a trade opens from. Carries the other person's shared list when there is one, so a
/// deep-linked trade and a hand-built one land on exactly the same screen.
struct TradeSessionRoute: Hashable {
    var offer: ShareList.Payload? = nil
}

/// A trade, across a table.
///
/// Two columns and a balance between them. The screen exists to answer one question out loud —
/// who is favored and by how much — to two people who are about to act on the answer, so every
/// number on it states what it is a share of and admits when it doesn't know.
///
/// Nothing is written until Execute. See `TradeSession` for why there is no trade ledger.
struct TradeSessionView: View {
    @Bindable var model: CollectionModel
    let store: CatalogStore
    var wants: WantsModel? = nil
    /// Incoming cards land here for review rather than straight into a divider. nil in contexts
    /// without a scanner tray, which disables execution rather than dropping the cards.
    var staging: ScanStagingStore? = nil
    /// A snapshot is written before the trade mutates anything — same safety rail as sync's
    /// seeding choice. nil in previews/tests.
    var backup: BackupService? = nil
    /// The list someone shared, if this trade opened from their link.
    var offer: ShareList.Payload? = nil
    /// Shows the staged cards straight after executing, so filing them is the obvious next step
    /// rather than something you discover later.
    var onExecuted: (() -> Void)? = nil

    @State private var session: TradeSession?
    @State private var pickingYours = false
    @State private var pickingTheirs = false
    @State private var confirmingExecute = false
    @State private var executing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                TinLoadingView(label: "Setting up…")
            }
        }
        .navigationTitle("Trade")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard session == nil else { return }
            let s = TradeSession(store: store)
            if let offer { s.seedTheirSide(from: offer) }
            session = s
        }
    }

    @ViewBuilder private func content(_ session: TradeSession) -> some View {
        List {
            balanceSection(session)
            if !session.theirs.lines.isEmpty { offersSection(session) }
            side(session, mine: true)
            side(session, mine: false)
            executeSection(session)
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $pickingYours) {
            NavigationStack {
                TradeOwnedPicker(model: model, store: store) { session.offer($0) }
            }
        }
        .sheet(isPresented: $pickingTheirs) {
            NavigationStack {
                TradeCatalogPicker(store: store, wants: wants) { card in
                    session.request(cardId: card.id, rarity: card.rarity)
                }
            }
        }
        .confirmationDialog("Execute this trade?", isPresented: $confirmingExecute,
                            titleVisibility: .visible) {
            Button("Execute trade", role: .destructive) { Task { await execute(session) } }
        } message: {
            Text(executeSummary(session))
        }
    }

    // MARK: Balance

    @ViewBuilder private func balanceSection(_ session: TradeSession) -> some View {
        let balance = session.balance
        Section {
            VStack(spacing: 8) {
                Text(favoredHeadline(balance))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                // The denominator, said out loud. A bare percentage across a table starts
                // arguments about what it was a percentage OF.
                if balance.favored != .even {
                    Text("Measured against the larger side, \(currency(max(balance.yourGive, balance.theirGive))).")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack {
                    column("You give", currency(balance.yourGive))
                    Spacer()
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                    Spacer()
                    column("They give", currency(balance.theirGive))
                }
                .padding(.top, 2)
                // Unpriced cards are surfaced, never silently counted as $0 — a balance that
                // hides what it doesn't know is worse than one that admits it.
                let u = session.unpriced
                if u.unpriced > 0 {
                    Text("\(u.unpriced) of \(Int(u.total)) cards have no price — not counted above.")
                        .font(.caption).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                if let asOf = model.priceAsOf { AsOfLabel(date: asOf) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }

    private func column(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }

    private func favoredHeadline(_ b: TradeBalance) -> String {
        switch b.favored {
        case .even: return b.yourGive == 0 ? "Nothing on the table yet" : "Even trade"
        case .you: return "You're favored by \(percent(b.percent))"
        case .them: return "They're favored by \(percent(b.percent))"
        }
    }

    // MARK: Offers

    /// "What would 95% look like?" — the question you cannot do in your head with fourteen cards
    /// on the table, and the reason someone opens a shared list in the app rather than reading it.
    @ViewBuilder private func offersSection(_ session: TradeSession) -> some View {
        let candidates = model.tradeEntries.map {
            TradeOfferBuilder.Candidate(entryId: $0.id, value: model.entryValue($0) ?? 0)
        }
        let suggestions = session.suggestions(from: candidates)
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { s in
                    Button {
                        session.apply(s, from: model.tradeEntries)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Offer \(s.percent)%").font(.body.weight(.medium))
                                Text(offerCaption(s))
                                    .font(.caption)
                                    .foregroundStyle(reached(s) == s.percent ? Color.secondary : Color.orange)
                            }
                            Spacer()
                            Text(currency(s.total)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .disabled(s.entryIds.isEmpty)
                }
            } header: {
                Text("Build your side")
            } footer: {
                Text("Picks from your For Trade list to reach that share of what you're taking. Tapping one replaces your side.")
            }
        }
    }

    private func reached(_ s: TradeOfferBuilder.Suggestion) -> Int {
        Int((s.achieved * 100).rounded())
    }

    /// Says what the pile actually comes to whenever that isn't the share on the label — a list
    /// worth less than their side can't reach 100%, and a row that never admits it is a claim.
    private func offerCaption(_ s: TradeOfferBuilder.Suggestion) -> String {
        let n = s.entryIds.count
        let cards = "\(n) \(n == 1 ? "card" : "cards")"
        return reached(s) == s.percent
            ? "\(cards) from your trade list"
            : "\(cards) — all your list reaches is \(reached(s))%"
    }

    // MARK: Columns

    @ViewBuilder private func side(_ session: TradeSession, mine: Bool) -> some View {
        let lines = mine ? session.yours.lines : session.theirs.lines
        Section {
            ForEach(lines) { line in
                lineRow(session, line: line, mine: mine)
            }
            .onDelete { offsets in
                let ids = offsets.map { lines[$0].id }
                for id in ids {
                    if mine { session.yours.remove(id: id) } else { session.theirs.remove(id: id) }
                }
                session.reprice()
            }
            Button {
                if mine { pickingYours = true } else { pickingTheirs = true }
            } label: {
                Label(mine ? "Add one of your cards" : "Add one of their cards",
                      systemImage: "plus.circle")
            }
            cashField(session, mine: mine)
        } header: {
            HStack {
                Text(mine ? "You give" : "They give")
                Spacer()
                Text(currency(mine ? session.balance.yourGive : session.balance.theirGive))
                    .monospacedDigit()
            }
        } footer: {
            if !mine {
                Text("Their cards come from the catalog — set each one's condition to price it honestly.")
            }
        }
    }

    @ViewBuilder private func lineRow(_ session: TradeSession, line: TradeLine, mine: Bool) -> some View {
        let card = try? store.card(id: line.entry.cardId)
        // Their condition picker gets a row of its own. Five segments beside a price and a stepper
        // is wider than an iPhone, and the ×N label used to be drawn OUTSIDE the stepper's bounds
        // by a fixed offset, so "DMG" and "×1" landed on top of each other as `DMG⊗1`.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(card?.name ?? line.entry.cardId).font(.body)
                        // What makes a shared list worth opening in the app: which of these you're
                        // actually hunting, answered without reading fourteen names.
                        if !mine, wants?.isWanted(line.entry.cardId) == true {
                            Image(systemName: "heart.fill")
                                .font(.caption2).foregroundStyle(.pink)
                                .accessibilityLabel("On your wanted list")
                        }
                    }
                    if mine { Text(subtitle(line)).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    if let v = session.pricing.lineValue(line) {
                        Text(currency(v)).monospacedDigit()
                    } else {
                        Text("No price").font(.caption).foregroundStyle(.orange)
                    }
                    HStack(spacing: 4) {
                        Text("×\(line.copies)").font(.caption).monospacedDigit()
                        Stepper("Copies", value: copiesBinding(session, line: line, mine: mine),
                                in: 1...(mine ? line.entry.qty : 99))
                            .labelsHidden()
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            if !mine {
                Picker("Condition", selection: conditionBinding(session, line: line)) {
                    ForEach(CardCondition.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private func subtitle(_ line: TradeLine) -> String {
        var parts: [String] = []
        if let v = line.entry.variantValue { parts.append(v.label) }
        if let c = line.entry.condition { parts.append(c) }
        if line.entry.qty > line.copies { parts.append("of \(line.entry.qty) owned") }
        return parts.joined(separator: " · ")
    }

    private func conditionBinding(_ session: TradeSession, line: TradeLine) -> Binding<CardCondition> {
        Binding(get: { line.entry.conditionValue ?? .nm },
                set: { session.setCondition($0, forTheirLine: line.id) })
    }

    private func copiesBinding(_ session: TradeSession, line: TradeLine, mine: Bool) -> Binding<Int> {
        Binding(get: { line.copies },
                set: { mine ? session.setCopies($0, forYourLine: line.id)
                            : session.setCopies($0, forTheirLine: line.id) })
    }

    @ViewBuilder private func cashField(_ session: TradeSession, mine: Bool) -> some View {
        // An explicit binding, not `$session` — the session arrives as a plain parameter (it is
        // held in `@State` as an Optional, unwrapped once at the top of `body`), so there is no
        // projected value to reach through.
        let cash = Binding(get: { mine ? session.yours.cashUsd : session.theirs.cashUsd },
                           set: { if mine { session.yours.cashUsd = $0 } else { session.theirs.cashUsd = $0 } })
        HStack {
            Label("Cash", systemImage: "dollarsign.circle")
            Spacer()
            TextField("0", value: cash,
                      format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
                .monospacedDigit()
        }
    }

    // MARK: Execute

    @ViewBuilder private func executeSection(_ session: TradeSession) -> some View {
        Section {
            Button {
                confirmingExecute = true
            } label: {
                if executing {
                    HStack { ProgressView(); Text("Executing…") }
                } else {
                    Text("Execute trade").frame(maxWidth: .infinity)
                }
            }
            .disabled(!session.isExecutable || executing || staging == nil)
        } footer: {
            Text(staging == nil
                 ? "Incoming cards need the scan tray, which isn't available here."
                 : "Cards you give are marked gone — they keep their cost basis and stop counting toward what you own. Cards you take land in the scan tray for review. Cash is not recorded anywhere.")
        }
    }

    private func executeSummary(_ session: TradeSession) -> String {
        let out = session.yours.cardCount, inn = session.theirs.cardCount
        return "\(out) \(out == 1 ? "card" : "cards") leave your tin, \(inn) \(inn == 1 ? "card lands" : "cards land") in the scan tray for review. This can't be undone in one tap."
    }

    private func execute(_ session: TradeSession) async {
        guard let staging else { return }
        executing = true
        defer { executing = false }
        // A snapshot BEFORE the writes, not after: the auto-backup fires on change and would
        // capture the post-trade state, which is the one state a restore can't help you leave.
        await backup?.backUpNow()

        let plan = session.plan()
        // The outgoing write first. Staging only fills once the tin has actually changed —
        // reversed, a failed write would hand you their cards while yours stayed put.
        guard await model.applyTradePlan(plan) else { return }
        for draft in plan.incomingDrafts { staging.append(draft) }
        dismiss()
        onExecuted?()
    }

    private func currency(_ v: Double) -> String {
        v.formatted(WidgetShared.tinCurrency(v))
    }

    private func percent(_ p: Double) -> String {
        (p).formatted(.percent.precision(.fractionLength(0...1)))
    }
}
