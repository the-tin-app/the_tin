import SwiftUI

/// Records that a copy has left the collection: when it went, and what you got for it.
///
/// Deliberately its own sheet rather than two more fields on `EntryFormView`. Marking a card gone
/// is a moment — you've just come back from a meetup — and it should be one gesture from the row,
/// not a trip through a form whose other eight fields you don't want to touch. It's also the
/// gesture that has to feel unmistakably *different* from Remove, which sits next to it and used
/// to be the only way to express this.
struct MarkSoldSheet: View {
    let card: CardRecord?
    let entry: CollectionEntry
    /// Current market value of the row, when the catalog can price it exactly — shown so you can
    /// see what you got against what it was worth, at the moment you type the number.
    var marketValue: Double?
    let onSave: (Date, Double?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var soldAt = Date()
    @State private var amountText = ""
    @FocusState private var amountFocused: Bool

    private var amount: Double? { EntryFormView.parseAmount(amountText) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Card", value: card?.name ?? entry.cardId)
                LabeledContent("Copy", value: sleeveText)
            }
            Section {
                DatePicker("Gone on", selection: $soldAt, displayedComponents: .date)
                TextField("What you got (USD)", text: $amountText)
                    .keyboardType(.decimalPad)
                    .focused($amountFocused)
            } footer: {
                // Traded and gifted cards are the common case in this hobby and neither has a
                // cash figure. The copy is still gone; we just can't say what it realised.
                Text("Leave the amount empty for a trade or a gift.")
            }
            if let paid = entry.pricePaid, paid > 0, let amount, amount > 0 {
                Section {
                    LabeledContent("You paid", value: paid.formatted(.currency(code: "USD")))
                    let change = amount - paid
                    LabeledContent("Realised") {
                        Text("\(change >= 0 ? "+" : "−")\(abs(change), format: .currency(code: "USD"))")
                            .foregroundStyle(change >= 0 ? Color.statusPositive : Color.statusNegative)
                            .monospacedDigit()
                    }
                }
            } else if let marketValue {
                Section {
                    LabeledContent("Market value", value: marketValue.formatted(.currency(code: "USD")))
                }
            }
            Section {
                Text("This copy stops counting toward your tin's value and keeps its history. It isn't deleted.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sold or traded")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await onSave(soldAt, amount)
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { amountFocused = false }
            }
        }
    }

    /// Same vocabulary as the row it was opened from, so there's no doubt which copy this is.
    private var sleeveText: String {
        var parts = ["×\(entry.qty)"]
        if let v = entry.variantValue { parts.append(v.label) }
        if let g = entry.gradeValue { parts.append(g.label) }
        else if let c = entry.condition { parts.append(c) }
        return parts.joined(separator: " · ")
    }
}
