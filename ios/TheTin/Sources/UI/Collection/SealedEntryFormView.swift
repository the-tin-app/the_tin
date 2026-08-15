import SwiftUI

/// Add or edit a sealed product you own — quantity plus the acquisition block, and nothing else.
///
/// Consciously much smaller than `EntryFormView`: there is no divider picker (sealed lives in its
/// own section, not behind a paper divider), no printing, no condition and no grade, because none
/// of those are facts about a shrink-wrapped box. What's left is the half the two forms genuinely
/// share, worded identically so the two screens read as siblings.
struct SealedEntryFormView: View {
    let product: SealedProduct
    var existing: SealedEntry?
    /// Returns whether the entry was actually persisted; the form only dismisses on true, so a
    /// failed write never silently discards what the user typed (same contract as `EntryFormView`).
    let onSave: (SealedEntry) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool
    @State private var qty = 1
    @State private var pricePaidText = ""
    @State private var acquiredVia: AcquiredVia? = nil
    @State private var hasAcquiredDate = false
    @State private var acquiredAt = Date()
    @State private var acquiredFrom = ""
    /// Snapshot of the fields as populated, so Cancel can tell typed-then-abandoned from
    /// untouched — only a dirty form earns a discard confirmation.
    @State private var baseline: [String] = []
    @State private var confirmingDiscard = false

    private var snapshot: [String] {
        [String(qty), pricePaidText, acquiredVia?.rawValue ?? "",
         hasAcquiredDate ? acquiredAt.description : "", acquiredFrom]
    }
    private var isDirty: Bool { snapshot != baseline }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    RemoteImage(url: product.imageURL)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(product.name).font(.subheadline.weight(.medium)).lineLimit(3)
                        if let market = product.marketUsd {
                            Text("\(market, format: .currency(code: "USD")) market")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Stepper("Quantity: \(qty)", value: $qty, in: 1...999)
            }
            Section("Acquisition") {
                Picker("Source", selection: $acquiredVia) {
                    Text("Not recorded").tag(AcquiredVia?.none)
                    ForEach(AcquiredVia.allCases) { Text($0.label).tag(AcquiredVia?.some($0)) }
                }
                TextField("Price paid — total (USD)", text: $pricePaidText)
                    .keyboardType(.decimalPad)
                    .focused($fieldFocused)
                Toggle("Acquired on", isOn: $hasAcquiredDate)
                if hasAcquiredDate {
                    DatePicker("Date", selection: $acquiredAt, displayedComponents: .date)
                }
                TextField("Acquired from (shop, show, trade…)", text: $acquiredFrom)
                    .focused($fieldFocused)
            }
        }
        .navigationTitle(existing == nil ? "Save to tin" : "Edit sealed product")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { if isDirty { confirmingDiscard = true } else { dismiss() } }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { fieldFocused = false }
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

    private func populate() {
        if let existing {
            qty = existing.qty
            pricePaidText = existing.pricePaid.map { String($0) } ?? ""
            acquiredVia = existing.acquiredViaValue
            hasAcquiredDate = existing.acquiredAt != nil
            acquiredAt = existing.acquiredAt ?? Date()
            acquiredFrom = existing.acquiredFrom ?? ""
        }
        baseline = snapshot
    }

    private func save() {
        Task {
            let entry = SealedEntry(
                id: existing?.id ?? UUID().uuidString,
                productId: product.tcgplayerId,
                qty: qty,
                // `EntryFormView.parseAmount`, not a second parser: it already handles the
                // locale trap where "1.234,56" would otherwise be silently dropped.
                pricePaid: EntryFormView.parseAmount(pricePaidText),
                acquiredAt: hasAcquiredDate ? acquiredAt : nil,
                acquiredFrom: acquiredFrom.isEmpty ? nil : acquiredFrom,
                acquiredVia: acquiredVia?.rawValue,
                addedAt: existing?.addedAt ?? Date(),
                // Carried, not rebuilt — this form makes a FRESH entry from its own state, and
                // `saveSealed` routes a known id to a full overwrite. Dropping these would
                // silently un-sell a sold box and resurrect it in the totals. Same trap, and the
                // same fix, as `EntryFormView`'s soldAt/soldFor.
                soldAt: existing?.soldAt,
                soldFor: existing?.soldFor)
            if await onSave(entry) { dismiss() }
        }
    }
}
