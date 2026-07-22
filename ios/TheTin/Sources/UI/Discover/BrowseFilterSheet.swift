import SwiftUI

/// The Browse filter editor. Edits a bound `BrowseCriteria` live; multi-select rows toggle set
/// membership. Presets save/apply/delete the whole criteria. `eras` is passed in (queried once).
struct BrowseFilterSheet: View {
    @Binding var criteria: BrowseCriteria
    let presets: BrowsePresetStore
    let eras: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var minText = ""
    @State private var maxText = ""
    @State private var newPresetName = ""
    /// Bumped each time a preset is applied, to fire a selection haptic (the tactile half of the
    /// "preset loaded" feedback; the checkmark is the visual half).
    @State private var appliedBump = 0
    @FocusState private var focusedField: Field?

    /// The three text inputs — tracked so a single keyboard-toolbar "Done" dismisses whichever is
    /// active (the decimal pad has no return key of its own).
    private enum Field: Hashable { case min, max, preset }

    /// Rarity tiers offered, in display order (verified full-art set + the base tiers).
    private let rarityOptions = ["Illustration rare", "Special illustration rare",
                                 "Secret Rare", "Ultra Rare", "Hyper rare"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Sort") {
                    Picker("Sort", selection: $criteria.sort) {
                        ForEach(BrowseSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }

                Section("Price (USD)") {
                    TextField("Min", text: $minText).keyboardType(.decimalPad)
                        .focused($focusedField, equals: .min)
                        .onChange(of: minText) { criteria.minPrice = Double(minText) }
                    TextField("Max", text: $maxText).keyboardType(.decimalPad)
                        .focused($focusedField, equals: .max)
                        .onChange(of: maxText) { criteria.maxPrice = Double(maxText) }
                }

                Section {
                    Toggle("On sale (dropped 7d)", isOn: $criteria.dealsOnly)
                    Toggle("Hide cards I own", isOn: $criteria.hideOwned)
                }

                multiSelect("Series", options: eras, selection: $criteria.eras)
                regionSelect()
                multiSelect("Rarity", options: rarityOptions, selection: $criteria.rarities)
                multiSelect("Type", options: DiscoverConstants.energyTypes, selection: $criteria.types)

                Section("Presets") {
                    ForEach(presets.presets) { preset in
                        Button {
                            criteria = preset.criteria; syncPriceText(); appliedBump += 1
                        } label: {
                            HStack {
                                Text(preset.name).foregroundStyle(.primary)
                                Spacer()
                                // Checkmark marks the preset whose criteria matches the current
                                // filter — i.e. the one just applied (until you tweak a filter).
                                if preset.criteria == criteria {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .onDelete { idx in idx.map { presets.presets[$0] }.forEach(presets.remove) }
                    HStack {
                        TextField("Save current as…", text: $newPresetName)
                            .focused($focusedField, equals: .preset)
                            .submitLabel(.done)
                            .onSubmit { focusedField = nil }
                        Button("Save") {
                            let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            presets.save(name: name, criteria: criteria)
                            newPresetName = ""
                        }.disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear all") { criteria = BrowseCriteria(); minText = ""; maxText = "" }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                // Decimal pad + plain text fields have no return key; this is the only way to
                // dismiss the keyboard.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sensoryFeedback(.selection, trigger: appliedBump)
            .onAppear { syncPriceText() }
        }
    }

    /// Mirror the numeric price bounds back into the editable text fields (on open, and after a
    /// preset replaces `criteria` wholesale). Typing flows the other way via the fields' onChange.
    private func syncPriceText() {
        minText = criteria.minPrice.map { String($0) } ?? ""
        maxText = criteria.maxPrice.map { String($0) } ?? ""
    }

    /// A section of tap-to-toggle rows backed by a `Set<String>` binding (checkmark = selected).
    private func multiSelect(_ title: String, options: [String],
                             selection: Binding<Set<String>>) -> some View {
        Section(title) {
            ForEach(options, id: \.self) { option in
                Button {
                    if selection.wrappedValue.contains(option) { selection.wrappedValue.remove(option) }
                    else { selection.wrappedValue.insert(option) }
                } label: {
                    HStack {
                        Text(option).foregroundStyle(.primary)
                        Spacer()
                        if selection.wrappedValue.contains(option) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
    }

    /// Region multi-select, backed by a `Set<Int>` of generation numbers (checkmark = selected).
    /// Parallel to `multiSelect` but Int-keyed, since regions persist by generation not by name.
    private func regionSelect() -> some View {
        Section("Region") {
            ForEach(PokemonRegion.all) { region in
                Button {
                    if criteria.regions.contains(region.gen) { criteria.regions.remove(region.gen) }
                    else { criteria.regions.insert(region.gen) }
                } label: {
                    HStack {
                        Text(region.label).foregroundStyle(.primary)
                        Spacer()
                        if criteria.regions.contains(region.gen) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
    }
}
