import SwiftUI

/// Add/edit a collection entry — every contract field (qty, condition, grade,
/// pricePaid, acquiredAt, acquiredFrom); cardId is always set from the card.
struct EntryFormView: View {
    let card: CardRecord
    let groups: [CardGroup]
    var existing: CollectionEntry?
    var variants: [VariantPrice] = []   // per-printing prices, for the inline picker labels
    var conditions: [ConditionPrice] = []   // per-condition prices, for the inline picker labels
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
                if groups.isEmpty {
                    TextField("New divider name", text: $newGroupName)
                } else {
                    Picker("Divider", selection: $groupId) {
                        ForEach(groups) { Text($0.name).tag($0.id) }
                    }
                }
                Stepper("Quantity: \(qty)", value: $qty, in: 1...999)
                Picker("Printing", selection: $variant) {
                    ForEach(CardVariant.allCases) { Text(variantLabel($0)).tag($0) }
                }
                Picker("Condition", selection: $condition) {
                    ForEach(CardCondition.allCases) { Text(conditionLabel($0)).tag($0) }
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
                TextField("Grading fee paid", text: $gradingFeeText)
                    .keyboardType(.decimalPad)
                    .focused($amountFieldFocused)
                Toggle("Acquired on", isOn: $hasAcquiredDate)
                if hasAcquiredDate {
                    DatePicker("Date", selection: $acquiredAt, displayedComponents: .date)
                }
                TextField("Acquired from (shop, show, trade…)", text: $acquiredFrom)
            }
        }
        .navigationTitle(existing == nil ? "Save to collection" : "Edit entry")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(groups.isEmpty ? newGroupName.trimmingCharacters(in: .whitespaces).isEmpty
                                             : groupId.isEmpty)
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

    /// "Reverse Holo · $140" when that printing is priced, else just the finish name.
    private func variantLabel(_ v: CardVariant) -> String {
        if let usd = v.price(in: variants) {
            return "\(v.label) · " + usd.formatted(.currency(code: "USD"))
        }
        return v.label
    }

    /// "DMG · $12" when that condition is priced, else just the condition name.
    private func conditionLabel(_ c: CardCondition) -> String {
        if let usd = conditions.first(where: { $0.condition == c.catalog })?.usd {
            return "\(c.rawValue) · " + usd.formatted(.currency(code: "USD"))
        }
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
            groupId = groups.first?.id ?? ""
            variant = .defaultFor(rarity: card.rarity)
        }
        baseline = snapshot
    }

    private func save() {
        Task {
            var resolvedGroupId = groupId
            if resolvedGroupId.isEmpty, let onCreateGroup {
                resolvedGroupId = await onCreateGroup(
                    newGroupName.trimmingCharacters(in: .whitespaces))
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
                pricePaid: Double(pricePaidText.replacingOccurrences(of: ",", with: ".")),
                gradingFeeUsd: Double(gradingFeeText.replacingOccurrences(of: ",", with: ".")),
                acquiredAt: hasAcquiredDate ? acquiredAt : nil,
                acquiredFrom: acquiredFrom.isEmpty ? nil : acquiredFrom,
                addedAt: existing?.addedAt ?? Date(),
                variant: variant.rawValue)
            if await onSave(entry) { dismiss() }
        }
    }
}
