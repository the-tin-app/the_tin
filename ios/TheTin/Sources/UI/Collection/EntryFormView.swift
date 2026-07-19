import SwiftUI

/// Add/edit a collection entry — every contract field (qty, condition, grade,
/// pricePaid, acquiredAt, acquiredFrom); cardId is always set from the card.
struct EntryFormView: View {
    let card: CardRecord
    let groups: [CardGroup]
    var existing: CollectionEntry?
    var variants: [VariantPrice] = []   // per-printing prices, for the inline picker labels
    var conditions: [ConditionPrice] = []   // per-condition prices, for the inline picker labels
    var matrix: [MatrixPrice] = []      // printing×condition cells, for printing-aware labels
    var onCreateGroup: ((String) async -> String)? = nil
    /// Returns whether the entry was actually persisted; the form only dismisses on true, so a
    /// failed write never silently discards what the user typed.
    let onSave: (CollectionEntry) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var amountFieldFocused: Bool
    @State private var groupId: String = ""
    @State private var newGroupName = ""
    @State private var qty = 1
    @State private var condition: CardCondition = .nm
    @State private var variant: CardVariant = .regular
    @State private var grade: Grade? = nil
    @State private var pricePaidText = ""
    @State private var gradingFeeText = ""
    @State private var hasAcquiredDate = false
    @State private var acquiredAt = Date()
    @State private var acquiredFrom = ""
    /// Snapshot of the fields as populated, so Cancel/swipe-down can tell typed-then-abandoned
    /// from untouched (only dirty forms earn a discard confirmation).
    @State private var baseline: [String] = []
    @State private var confirmingDiscard = false

    private var snapshot: [String] {
        [groupId, newGroupName, String(qty), condition.rawValue, variant.rawValue,
         grade.map(String.init(describing:)) ?? "", pricePaidText, gradingFeeText,
         hasAcquiredDate ? acquiredAt.description : "", acquiredFrom]
    }
    private var isDirty: Bool { snapshot != baseline }

    var body: some View {
        Form {
            Section(card.name) {
                if groups.isEmpty, onCreateGroup != nil {
                    // First card, no dividers yet: filing is optional — leave blank and it
                    // lands in the tin, same as a scan.
                    TextField("New divider name (optional)", text: $newGroupName)
                } else if !groups.isEmpty {
                    Picker("Divider", selection: $groupId) {
                        Text("No divider").tag("")
                        ForEach(groups) { Text($0.name).tag($0.id) }
                    }
                }
                Stepper("Quantity: \(qty)", value: $qty, in: 1...999)
                Picker("Printing", selection: $variant) {
                    ForEach(Self.validVariants(catalog: variants, current: existing?.variantValue)) {
                        Text(variantLabel($0)).tag($0)
                    }
                }
                // A graded card's condition IS its grade — the raw-condition picker only
                // applies (and only shows) when the copy is raw. Always all five conditions:
                // condition is a fact about the user's copy, not the catalog (2026-07-17) —
                // an unpriced pick just shows "no data" (PR #20 honesty rules).
                if grade == nil {
                    Picker("Condition", selection: $condition) {
                        ForEach(CardCondition.allCases) { Text(conditionLabel($0)).tag($0) }
                    }
                }
                Picker("Grade", selection: $grade) {
                    Text("Raw").tag(Grade?.none)
                    ForEach(Grade.allCases) { Text($0.label).tag(Grade?.some($0)) }
                }
            }
            Section("Acquisition") {
                TextField("Price paid — total (USD)", text: $pricePaidText)
                    .keyboardType(.decimalPad)
                    .focused($amountFieldFocused)
                if grade != nil {
                    TextField("Grading fee paid", text: $gradingFeeText)
                        .keyboardType(.decimalPad)
                        .focused($amountFieldFocused)
                }
                Toggle("Acquired on", isOn: $hasAcquiredDate)
                if hasAcquiredDate {
                    DatePicker("Date", selection: $acquiredAt, displayedComponents: .date)
                }
                TextField("Acquired from (shop, show, trade…)", text: $acquiredFrom)
            }
        }
        .navigationTitle(existing == nil ? "Save to tin" : "Edit entry")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if isDirty { confirmingDiscard = true } else { dismiss() }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { amountFieldFocused = false }
            }
        }
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog("Discard what you've entered?", isPresented: $confirmingDiscard,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .onAppear(perform: populate)
    }

    /// Printings the picker offers: only the finishes the catalog's `price_by_variant` actually
    /// names for this card — a card never sold as 1st Edition shouldn't offer it. The saved
    /// entry's finish is always kept so editing never silently rewrites what the user recorded.
    /// No variant rows at all ⇒ the full list (no data ≠ doesn't exist; minimal tiers).
    static func validVariants(catalog: [VariantPrice], current: CardVariant?) -> [CardVariant] {
        let backed = CardVariant.allCases.filter { v in catalog.contains { v.matches(printing: $0.printing) } }
        guard !backed.isEmpty else { return CardVariant.allCases }
        return CardVariant.allCases.filter { backed.contains($0) || $0 == current }
    }

    /// "Reverse Holo · $140" when that printing is priced, else just the finish name.
    private func variantLabel(_ v: CardVariant) -> String {
        if let usd = v.price(in: variants) {
            return "\(v.label) · " + usd.formatted(.currency(code: "USD"))
        }
        return v.label
    }

    /// "DMG · $12" when that condition is priced — preferring the SELECTED printing's matrix
    /// cell over the card-level condition price — else just the condition name.
    private func conditionLabel(_ c: CardCondition) -> String {
        let usd = matrix.first { $0.condition == c.catalog && variant.matches(printing: $0.printing) }?.usd
            ?? conditions.first { $0.condition == c.catalog }?.usd
        if let usd { return "\(c.rawValue) · " + usd.formatted(.currency(code: "USD")) }
        return c.rawValue
    }

    private func populate() {
        if let existing {
            groupId = existing.groupId
            qty = existing.qty
            condition = existing.condition.flatMap(CardCondition.init(rawValue:)) ?? .nm
            variant = existing.variantValue ?? .defaultFor(rarity: card.rarity)
            grade = existing.gradeValue
            pricePaidText = existing.pricePaid.map { String($0) } ?? ""
            gradingFeeText = existing.gradingFeeUsd.map { String($0) } ?? ""
            hasAcquiredDate = existing.acquiredAt != nil
            acquiredAt = existing.acquiredAt ?? Date()
            acquiredFrom = existing.acquiredFrom ?? ""
        } else {
            // New entries default to the tin itself, matching the scanner — filing behind a
            // divider is a choice, never a requirement.
            groupId = ""
            variant = .defaultFor(rarity: card.rarity)
            // The rarity heuristic can suggest a finish this card was never sold in — clamp
            // to the offered list so the picker never starts on a hidden option.
            let offered = Self.validVariants(catalog: variants, current: nil)
            if !offered.contains(variant) { variant = offered.first ?? .regular }
        }
        baseline = snapshot
    }

    private func save() {
        Task {
            var resolvedGroupId = groupId
            let newName = newGroupName.trimmingCharacters(in: .whitespaces)
            if groups.isEmpty, !newName.isEmpty, let onCreateGroup {
                resolvedGroupId = await onCreateGroup(newName)
                // Group creation failed (already alerted); keep the form open so nothing typed
                // is lost and Save can be retried.
                guard !resolvedGroupId.isEmpty else { return }
            }
            let entry = CollectionEntry(
                id: existing?.id ?? UUID().uuidString,
                cardId: card.id,
                groupId: resolvedGroupId,
                qty: qty,
                condition: condition.rawValue,
                grade: grade?.rawValue,
                pricePaid: Self.parseAmount(pricePaidText),
                gradingFeeUsd: Self.parseAmount(gradingFeeText),
                acquiredAt: hasAcquiredDate ? acquiredAt : nil,
                acquiredFrom: acquiredFrom.isEmpty ? nil : acquiredFrom,
                addedAt: existing?.addedAt ?? Date(),
                variant: variant.rawValue)
            if await onSave(entry) { dismiss() }
        }
    }

    /// Locale-aware amount parse: "1,234.56" (en) and "1.234,56" (de) both land instead of
    /// being silently dropped — a bare Double() init chokes on any grouping separator.
    static func parseAmount(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return (try? Double(t, format: .number))
            ?? Double(t.replacingOccurrences(of: ",", with: "."))
    }
}
