import SwiftUI

/// Edit a wishlist card's priority / price target / notes. Writes via `WantsModel.update`,
/// which no-ops if the card isn't wanted, so this is only presented for wanted cards.
struct WishlistEditSheet: View {
    let card: CardRecord
    let price: Double?
    let wants: WantsModel
    @Environment(\.dismiss) private var dismiss

    @State private var priority: WantPriority = .normal
    @State private var targetText = ""
    @State private var notes = ""

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
                    TextField("e.g. 25.00", text: $targetText).keyboardType(.decimalPad)
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
                }
            }
            .navigationTitle("Wishlist details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save(); dismiss() } }
            }
            .onAppear {
                let e = wants.entry(card.id) ?? WantEntry()
                priority = e.priority
                targetText = e.targetUsd.map { String(format: "%.2f", $0) } ?? ""
                notes = e.notes
            }
        }
    }

    private func save() {
        let target = Double(targetText.trimmingCharacters(in: .whitespaces))
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        wants.update(card.id) { e in
            e.priority = priority
            e.targetUsd = target
            e.notes = cleanNotes
        }
    }
}
