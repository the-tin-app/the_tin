import SwiftUI

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
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save(); dismiss() } }
                // ⚠️ **A `.decimalPad` field in a `Form` has no way out without this.** There is no
                // return key on that keypad, and a `Form` does not dismiss on tap-outside — so the
                // keyboard stayed up over the hunting section for as long as the sheet was open.
                // Worse here than at the app's nine other decimal-pad fields, all of which already
                // had this: `huntingSection` FOCUSES this field when you switch Hunting on without
                // a budget, so the app raised a keyboard the user didn't ask for, over the footer
                // explaining why they needed one, with no way to lower it.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { targetFocused = false }
                }
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
                    if on, budget == nil { targetFocused = true }
                }
            ))
            if hunting {
                Picker("Condition floor", selection: $minCondition) {
                    ForEach(Self.floors) { Text($0.floorLabel).tag($0) }
                }
            }
        } header: {
            Text("Hunting")
        } footer: {
            if hunting && budget == nil {
                // A hunt with no budget has nothing to compare against, so the eBay search has
                // no ceiling and the sort has nothing to rank it by. Say so rather than saving
                // something inert.
                Text("Set a price target above — a hunt needs a budget to search against.")
            } else if hunting {
                // No expiry to mention: a hunt runs until you switch it off. Deliberately says
                // nothing about being notified — eBay's saved search is a DAILY email, and the
                // app itself no longer sends anything.
                Text("Shows this card under Watching and Wishlist → Hunting, with a one-tap search.")
            }
        }
    }

    private func load() {
        let e = wants.entry(card.id) ?? WantEntry()
        priority = e.priority
        targetText = e.targetUsd.map { String(format: "%.2f", $0) } ?? ""
        notes = e.notes
        // A stored hunt is a live hunt now — there is no expiry to test.
        if let h = e.hunt {
            minCondition = h.minCondition
            hunting = true
        }
    }

    private func save() {
        let target = budget
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        wants.update(card.id) { e in
            e.priority = priority
            e.targetUsd = target
            e.notes = cleanNotes
            // A hunt without a budget has no search ceiling and nothing for `huntSorted` to
            // rank, so don't store one.
            e.hunt = (hunting && target != nil) ? Hunt(minCondition: minCondition) : nil
        }
    }
}
