import SwiftUI

/// Set the same facts on many cards at once — "I got all of these at the show on the 14th".
///
/// Mirrors `EntryFormView`'s Acquisition section field for field, with one difference that governs
/// the whole screen: **every control has a "Leave unchanged" state and starts in it.** Opening this
/// sheet and tapping Apply must be incapable of writing anything. A blank text field here means
/// "keep what's there", not "erase it" — clearing a field stays a single-card edit, where you can
/// see the one row you're emptying.
struct BulkEditSheet: View {
    let entries: [CollectionEntry]
    let onApply: (BulkEdit) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var setDate = false
    @State private var acquiredAt = Date()
    @State private var acquiredFrom = ""
    @State private var acquiredVia: AcquiredVia?
    @State private var priceText = ""
    @State private var priceIsLot = false
    @State private var condition: CardCondition?
    @State private var variant: CardVariant?
    @State private var forTrade: Bool?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Form {
            // `header:` rather than `Section("Acquisition") { … } footer: { … }` — there is no
            // `Section(_:content:footer:)`, and with a title string in that position the compiler
            // reads the String as the CONTENT and reports it three types away from the mistake.
            Section {
                Picker("How acquired", selection: $acquiredVia) {
                    Text("Leave unchanged").tag(AcquiredVia?.none)
                    ForEach(AcquiredVia.allCases) { Text($0.label).tag(AcquiredVia?.some($0)) }
                }
                Toggle("Set acquired date", isOn: $setDate)
                if setDate {
                    DatePicker("Date", selection: $acquiredAt, displayedComponents: .date)
                }
                TextField("Acquired from (shop, show, trade…)", text: $acquiredFrom)
                    .focused($fieldFocused)
            } header: {
                Text("Acquisition")
            } footer: {
                Text("Blank fields are left as they are.")
            }
            Section {
                TextField("Amount (USD)", text: $priceText)
                    .keyboardType(.decimalPad)
                    .focused($fieldFocused)
                // Segmented, and always visible rather than revealed by typing: which of the two a
                // number means is the whole question, and finding out after the fact costs you the
                // cost basis on every card in the selection.
                Picker("Meaning", selection: $priceIsLot) {
                    Text("Each card").tag(false)
                    Text("Total for lot").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Price paid")
            } footer: {
                Text(priceIsLot
                     ? "Split across the \(cardCount) by quantity — the shares add up to exactly what you typed."
                     : "Each card gets this amount, multiplied by how many copies that row holds.")
            }
            Section {
                Picker("Condition", selection: $condition) {
                    Text("Leave unchanged").tag(CardCondition?.none)
                    ForEach(CardCondition.allCases) { Text($0.rawValue).tag(CardCondition?.some($0)) }
                }
                // The four finishes only. A catalog print run names ONE card's printing, so
                // offering it across a mixed selection would mis-value everything else in it.
                Picker("Printing", selection: $variant) {
                    Text("Leave unchanged").tag(CardVariant?.none)
                    ForEach(CardVariant.allCases) { Text($0.label).tag(CardVariant?.some($0)) }
                }
                Picker("Available to trade", selection: $forTrade) {
                    Text("Leave unchanged").tag(Bool?.none)
                    Text("Yes").tag(Bool?.some(true))
                    Text("No").tag(Bool?.some(false))
                }
            } header: {
                Text("Copy details")
            } footer: {
                if gradedCount > 0, condition != nil {
                    // Said here rather than silently skipped: the rule is right, but a count that
                    // doesn't match what you selected reads as a bug unless the screen explains it.
                    Text("A graded card's condition is its grade, so \(gradedCount == 1 ? "1 slab" : "\(gradedCount) slabs") in this selection keep theirs.")
                }
            }
            Section {
                Text(summary).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Edit \(cardCount)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    let edit = edit
                    Task {
                        await onApply(edit)
                        dismiss()
                    }
                }
                .disabled(edit.isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { fieldFocused = false }
            }
        }
    }

    private var edit: BulkEdit {
        let amount = EntryFormView.parseAmount(priceText)
        return BulkEdit(
            acquiredAt: setDate ? acquiredAt : nil,
            acquiredFrom: acquiredFrom.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : acquiredFrom.trimmingCharacters(in: .whitespaces),
            acquiredVia: acquiredVia,
            price: amount.map { priceIsLot ? .lot($0) : .each($0) },
            condition: condition,
            variant: variant,
            forTrade: forTrade)
    }

    /// What Apply is about to do, in cards. The overwrite count is the point of this line: your
    /// placeholder dates are exactly the thing you came here to replace, but a real cost basis
    /// typed in one at a time is exactly the thing you didn't.
    private var summary: String {
        guard !edit.isEmpty else { return "Nothing selected to change yet." }
        let replaced = edit.overwrites(in: entries)
        guard replaced > 0 else { return "Applies to \(cardCount). Nothing will be overwritten." }
        return "Applies to \(cardCount). \(replaced) already \(replaced == 1 ? "has a value" : "have values") that will be replaced."
    }

    private var cardCount: String { "\(entries.count) \(entries.count == 1 ? "card" : "cards")" }
    private var gradedCount: Int { entries.filter { $0.grade != nil }.count }
}
