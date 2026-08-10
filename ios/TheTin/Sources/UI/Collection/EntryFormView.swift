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
    @State private var acquiredVia: AcquiredVia? = nil
    @State private var forTrade = false
    /// Fixed for the life of the form so a photo taken BEFORE Save has a stable key. `save()`
    /// used to mint the id inline, which is too late — the file would be written under one id and
    /// the entry saved under another.
    @State private var entryId = ""
    @State private var photos = EntryPhotos()
    /// Which photo tile was tapped. Lives here, not in the section, because the presentation it
    /// drives has to be attached to the Form's root — see `photoCapture(...)`.
    @State private var photoRequest: PhotoRequest?
    /// `populate()` is a one-shot; see the `onAppear` at the end of the body.
    @State private var populated = false
    /// Snapshot of the fields as populated, so Cancel/swipe-down can tell typed-then-abandoned
    /// from untouched (only dirty forms earn a discard confirmation).
    @State private var baseline: [String] = []
    @State private var confirmingDiscard = false

    private var snapshot: [String] {
        [groupId, newGroupName, String(qty), condition.rawValue, variant.rawValue,
         grade.map(String.init(describing:)) ?? "", pricePaidText, gradingFeeText,
         hasAcquiredDate ? acquiredAt.description : "", acquiredFrom, String(forTrade),
         acquiredVia?.rawValue ?? "", photos.all.joined(separator: ",")]
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
                // How the copy arrived. "Not recorded" is a real choice and the default: the
                // form used to assume you bought it, and nil must stay distinguishable from
                // an actual answer.
                Picker("Source", selection: $acquiredVia) {
                    Text("Not recorded").tag(AcquiredVia?.none)
                    ForEach(AcquiredVia.allCases) { Text($0.label).tag(AcquiredVia?.some($0)) }
                }
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
            Section {
                Toggle("Available to trade", isOn: $forTrade)
            } footer: {
                Text("Collects this copy in your trade list, which you can share as a link or print as a sheet.")
            }
            EntryPhotosSection(entryId: entryId, photos: $photos, request: $photoRequest)
        }
        // ⚠️ On the Form, NOT on the section above. Attached to the Section this presented and
        // instantly dismissed itself, closing the whole entry sheet with it (device, 2026-08-10).
        .photoCapture(entryId: entryId, photos: $photos, request: $photoRequest)
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
        // ⚠️ ONCE. `onAppear` fires again every time something presented over this form goes
        // away — the camera cover, the photo picker, the discard dialog — and `populate()` resets
        // every field to what's persisted. A photo taken and saved to disk was wiped from `photos`
        // on the way back ("upload photo, nothing happened", device 2026-08-10), and for a NEW
        // entry `entryId` was re-minted too, orphaning the file that had just been written under
        // the old id. Everything else typed before opening the camera was silently reverted the
        // same way; the photo is just what made it visible.
        .onAppear {
            PhotoDiag.record("onAppear", populated ? "already populated — skipped" : "populating")
            if !populated { populated = true; populate() }
        }
    }

    /// The finishes the catalog's `price_by_variant` actually names for this card — a card never
    /// sold as 1st Edition shouldn't offer it. No variant rows at all ⇒ the full list (no data ≠
    /// doesn't exist; minimal tiers). Unlike `validVariants` this does NOT fold in a current
    /// selection, so callers can tell whether a given finish is genuinely offered.
    ///
    /// The catalog names PRINT RUNS now, not only finishes — "Cosmos Holo", "World Championship
    /// Decks 2004". Those are offered as themselves; the four finishes still come first and in
    /// their canonical order, so the picker an ordinary card shows is exactly what it was.
    static func offeredVariants(catalog: [VariantPrice]) -> [CardVariant] {
        let named = catalog.compactMap { CardVariant(rawValue: $0.printing) }
        var backed = CardVariant.allCases.filter(named.contains)
        for v in named where !CardVariant.allCases.contains(v) && !backed.contains(v) { backed.append(v) }
        return backed.isEmpty ? CardVariant.allCases : backed
    }

    /// Printings the picker offers: the offered finishes plus the saved/selected finish, so
    /// editing never silently rewrites what the user recorded even if the catalog no longer
    /// names it.
    static func validVariants(catalog: [VariantPrice], current: CardVariant?) -> [CardVariant] {
        let offered = offeredVariants(catalog: catalog)
        guard let current, !offered.contains(current) else { return offered }
        return offered + [current]
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
        entryId = existing?.id ?? UUID().uuidString
        photos = existing?.photos ?? EntryPhotos()
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
            forTrade = existing.isForTrade
            acquiredVia = existing.acquiredViaValue
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
                id: entryId,
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
                variant: variant.rawValue,
                // nil rather than false when off, so an entry that was never marked stays
                // byte-identical to what it was before this field existed.
                forTrade: forTrade ? true : nil,
                // Carried, not rebuilt. This form constructs a FRESH entry from its own state, so
                // any field it doesn't own defaults away — and `CollectionModel.saveEntry` routes
                // a known id to `updateEntry`, a full overwrite. Drop these two and a sold copy
                // silently un-sells itself: the sale record is gone and the card reappears in the
                // tin's totals. Unreachable today (the Gone section offers only "Bring back" and
                // "Delete"), but `saveEntry`'s own comment says "a sold row edited from the Gone
                // section", so the next person to add that affordance would trip a live data-loss
                // bug with a comment reassuring them it was handled.
                soldAt: existing?.soldAt,
                soldFor: existing?.soldFor,
                acquiredVia: acquiredVia?.rawValue,
                // nil rather than an empty set when nothing was taken, so an entry that was
                // never photographed stays byte-identical to what it was before this field
                // existed — the same rule `forTrade` follows above.
                photos: photos.isEmpty ? nil : photos)
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
