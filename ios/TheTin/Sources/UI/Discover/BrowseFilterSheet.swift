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
                        .onChange(of: minText) { criteria.minPrice = Double(minText) }
                    TextField("Max", text: $maxText).keyboardType(.decimalPad)
                        .onChange(of: maxText) { criteria.maxPrice = Double(maxText) }
                }

                Section {
                    Toggle("On sale (dropped 7d)", isOn: $criteria.dealsOnly)
                    Toggle("Hide cards I own", isOn: $criteria.hideOwned)
                }

                multiSelect("Generation", options: eras, selection: $criteria.eras)
                multiSelect("Rarity", options: rarityOptions, selection: $criteria.rarities)
                multiSelect("Type", options: DiscoverConstants.energyTypes, selection: $criteria.types)

                Section("Presets") {
                    ForEach(presets.presets) { preset in
                        Button(preset.name) { criteria = preset.criteria }
                    }
                    .onDelete { idx in idx.map { presets.presets[$0] }.forEach(presets.remove) }
                    HStack {
                        TextField("Save current as…", text: $newPresetName)
                        Button("Save") {
                            guard !newPresetName.isEmpty else { return }
                            presets.save(name: newPresetName, criteria: criteria)
                            newPresetName = ""
                        }.disabled(newPresetName.isEmpty)
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
            }
        }
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
}
