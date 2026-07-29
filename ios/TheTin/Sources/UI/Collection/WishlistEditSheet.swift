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
    @State private var existingUntil: Date?
    @FocusState private var targetFocused: Bool

    /// Conditions offered as a floor. DMG is absent on purpose: "I'll take a damaged one"
    /// is not a floor, it's the absence of one, and nobody hunting a grail means it.
    private static let floors: [CardCondition] = [.hp, .lp, .nm]

    private func floorLabel(_ c: CardCondition) -> String {
        switch c {
        case .hp: return "Anything but DMG"
        case .lp: return "LP or better"
        case .nm: return "NM only"
        case .mp, .dmg: return c.rawValue
        }
    }

    private var budget: Double? { Double(targetText.trimmingCharacters(in: .whitespaces)) }

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
                        // Switching on by hand always starts a fresh window. `load()` assigns
                        // `hunting` directly, so it never routes through here and a stored
                        // deadline survives a reopen.
                        existingUntil = nil
                        if budget == nil { targetFocused = true }
                    }
                }
            ))
            if hunting {
                Picker("Condition floor", selection: $minCondition) {
                    ForEach(Self.floors) { Text(floorLabel($0)).tag($0) }
                }
                Picker("Buying within", selection: $window) {
                    ForEach(HuntWindow.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Expires",
                               value: (existingUntil ?? window.until()).formatted(date: .abbreviated,
                                                                                  time: .omitted))
                .foregroundStyle(.secondary)
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
            }
        }
        .onChange(of: window) { _, _ in existingUntil = nil }
    }

    private func load() {
        let e = wants.entry(card.id) ?? WantEntry()
        priority = e.priority
        targetText = e.targetUsd.map { String(format: "%.2f", $0) } ?? ""
        notes = e.notes
        // An expired hunt reads as "not hunting" — the toggle is off and the sheet offers a
        // fresh window rather than showing a date that has already passed.
        if let h = e.hunt, h.isActive {
            hunting = true
            minCondition = h.minCondition
            existingUntil = h.until
        }
    }

    private func save() {
        let target = budget
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        wants.update(card.id) { e in
            e.priority = priority
            e.targetUsd = target
            e.notes = cleanNotes
            // A hunt without a budget can never fire, so don't store one.
            e.hunt = (hunting && target != nil)
                ? Hunt(minCondition: minCondition, until: existingUntil ?? window.until())
                : nil
        }
    }
}
