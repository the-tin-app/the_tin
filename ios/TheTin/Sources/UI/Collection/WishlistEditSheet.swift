import SwiftUI

/// How long you're giving yourself to buy. Stored as an absolute `until` date at save time,
/// so reopening the sheet a week later doesn't silently restart the clock.
enum HuntWindow: Int, CaseIterable, Identifiable {
    case d7 = 7, d14 = 14, d30 = 30
    var id: Int { rawValue }
    var label: String { "\(rawValue) days" }
    func until(from: Date = Date()) -> Date { from.addingTimeInterval(Double(rawValue) * 86_400) }
}

/// Edit a wishlist card's priority / price target / notes / hunt. Writes via `WantsModel.update`,
/// which no-ops if the card isn't wanted, so this is only presented for wanted cards.
struct WishlistEditSheet: View {
    let card: CardRecord
    let price: Double?
    let wants: WantsModel
    @Environment(\.dismiss) private var dismiss

    @State private var priority: WantPriority = .normal
    @State private var targetText = ""
    @State private var notes = ""
    @State private var hunting = false
    @State private var minCondition: CardCondition = .hp
    @State private var window: HuntWindow = .d14
    /// Preserved when reopening a live hunt so "expires Aug 11" doesn't drift on every visit.
    /// Non-nil also means "this hunt's clock is already running", which is why the window picker
    /// is hidden while it is set: `until` cannot be inverted back into a 7/14/30 choice (the
    /// creation date isn't stored), so a picker beside it would show a default that contradicts
    /// the date — and truncate a 30-day hunt to 14 on the first touch.
    @State private var existingUntil: Date?
    /// A stored hunt that has already expired. The toggle reads off, but the floor is preserved
    /// so switching Hunting back on RENEWS the hunt rather than restarting from defaults — and
    /// `save()` writes it back untouched if the user never touches the toggle.
    @State private var lapsedUntil: Date?
    @FocusState private var targetFocused: Bool

    /// Conditions offered as a floor. DMG is absent on purpose: "I'll take a damaged one"
    /// is not a floor, it's the absence of one, and nobody hunting a grail means it.
    private static let floors: [CardCondition] = [.hp, .lp, .nm]

    /// A non-positive budget is no budget: `Double("0")` is non-nil, and a zero-target hunt
    /// would be stored, promised in the footer, then silently dropped by `huntSorted`'s
    /// `target > 0` guard. One definition of "has a budget", used by the footer and by save().
    ///
    /// `Double(_:)` only accepts "." while `.decimalPad` shows the LOCALE's separator, so a
    /// French "300,00" parsed as nil — and since save() writes `targetUsd = budget` and drops
    /// the hunt when the budget is nil, opening the sheet and pressing Done deleted both fields.
    /// Static and separator-injectable so that can be tested without a view host.
    static func parseBudget(_ text: String,
                            separator: String = Locale.current.decimalSeparator ?? ".") -> Double? {
        let normalised = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: separator, with: ".")
        guard let v = Double(normalised), v > 0 else { return nil }
        return v
    }

    private var budget: Double? { Self.parseBudget(targetText) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        CardImageView(card: card, quality: "low").frame(width: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name).font(.headline).lineLimit(2)
                            if let price {
                                Text("Market \(price, format: .currency(code: "USD"))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Priority") {
                    Picker("Priority", selection: $priority) {
                        ForEach(WantPriority.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section("Price target (USD)") {
                    TextField("e.g. 25.00", text: $targetText)
                        .keyboardType(.decimalPad)
                        .focused($targetFocused)
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
                }
                huntingSection
            }
            .navigationTitle("Wishlist details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save(); dismiss() } }
            }
            .onAppear(perform: load)
        }
    }

    @ViewBuilder private var huntingSection: some View {
        Section {
            Toggle("Hunting", isOn: Binding(
                get: { hunting },
                set: { on in
                    hunting = on
                    if on {
                        // Switching on by hand always starts a fresh window — including the
                        // renewal of a lapsed hunt, which keeps its floor but not its old date.
                        // `load()` assigns `hunting` directly, so it never routes through here
                        // and a live hunt's stored deadline survives a reopen.
                        existingUntil = nil
                        if budget == nil { targetFocused = true }
                    }
                }
            ))
            if hunting {
                Picker("Condition floor", selection: $minCondition) {
                    ForEach(Self.floors) { Text($0.floorLabel).tag($0) }
                }
                // The window picker only appears while choosing one. A running hunt shows its
                // real expiry instead, plus the one control that can legitimately change it.
                if let existingUntil {
                    LabeledContent("Expires",
                                   value: existingUntil.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                    Button("Start a new window") { self.existingUntil = nil }
                } else {
                    Picker("Buying within", selection: $window) {
                        ForEach(HuntWindow.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Expires",
                                   value: window.until().formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Hunting")
        } footer: {
            if hunting && budget == nil {
                // A hunt with no budget has nothing to compare against, so it can never
                // produce an alert. Say so rather than saving something inert.
                Text("Set a price target above — a hunt needs a budget to watch against.")
            } else if hunting {
                Text("Shows this card under Wanted → Hunting with a one-tap search.")
            } else if let lapsedUntil {
                Text("This hunt ran out on \(lapsedUntil.formatted(date: .abbreviated, time: .omitted)). Switch Hunting on to renew it — your condition floor is still set.")
            }
        }
    }

    private func load() {
        let e = wants.entry(card.id) ?? WantEntry()
        priority = e.priority
        targetText = e.targetUsd.map { String(format: "%.2f", $0) } ?? ""
        notes = e.notes
        // The floor is restored either way: an expired hunt still says which condition you'd
        // accept, and renewing should not make you choose it again. Only `isActive` decides
        // whether the toggle reads on and the window keeps running.
        if let h = e.hunt {
            minCondition = h.minCondition
            if h.isActive { hunting = true; existingUntil = h.until } else { lapsedUntil = h.until }
        }
    }

    private func save() {
        let target = budget
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        wants.update(card.id) { e in
            e.priority = priority
            e.targetUsd = target
            e.notes = cleanNotes
            // A hunt without a budget can never fire, so don't store one. A LAPSED hunt is kept
            // as-is: it's inert everywhere (`isActive` gates the Hunting list, the sort and the
            // alerts), and dropping it would destroy the floor the user chose just because they
            // opened the sheet.
            e.hunt = (hunting && target != nil)
                ? Hunt(minCondition: minCondition, until: existingUntil ?? window.until())
                : lapsedUntil.map { Hunt(minCondition: minCondition, until: $0) }
        }
    }
}
