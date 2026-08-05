import SwiftUI

/// Asked once, the first time For You has nothing to go on.
///
/// Cold start used to fall back to `topPricedCards`, so a brand-new user's first impression of a
/// feature about *what you would actually buy* was a wall of $3,000–$4,500 grails. Rather than
/// guess, this asks — once — and writes into two things that already exist.
///
/// ⚠️ **It asks about sets, never species, and that is a review decision as much as a product one.**
/// This is the first screen a new user meets, and therefore the first screen an App Review reviewer
/// meets. Build 21 deliberately scrubbed the branded vocabulary from the running app
/// ("Pokédex"→"Dex", region names→"Gen N") after three 4.1(a) rejections; a first-run grid of
/// Pokémon names and art would be the densest possible version of exactly that, on the one screen a
/// reviewer cannot miss.
///
/// The set answer is worth more anyway: it writes `SetGoals` — previously the biggest unused signal
/// in the app — it gives the goal shelves content on day one, and a set implies its species, era and
/// rarity mix for free through `Profile.sets`.
struct ForYouSeedView: View {
    let sets: [SetRecord]
    let goals: SetGoalsModel?
    let onDone: () -> Void

    @State private var budget: DiscoverBudget?
    @State private var chosen: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(sets) { record in
                        Button { toggle(record.id) } label: {
                            HStack {
                                Text(record.name).foregroundStyle(.primary)
                                Spacer()
                                if chosen.contains(record.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityAddTraits(chosen.contains(record.id) ? .isSelected : [])
                    }
                } header: {
                    Text("Which sets are you working on?")
                } footer: {
                    Text("We'll show you what's missing from them.")
                }

                Section {
                    ForEach(DiscoverBudget.allCases.filter { $0 != .skipped }, id: \.self) { option in
                        Button { budget = option } label: {
                            HStack {
                                Text(option.label).foregroundStyle(.primary)
                                Spacer()
                                if budget == option {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityAddTraits(budget == option ? .isSelected : [])
                    }
                } header: {
                    Text("Roughly what do you spend on a card?")
                } footer: {
                    Text("Only used to pick what to show you. It updates itself once you've recorded a few purchases.")
                }
            }
            .navigationTitle("Set up For You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { finish(.skipped) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // `.skipped` is a real stored answer, so tapping Done with nothing chosen is
                    // recorded and never asked again.
                    Button("Done") { finish(budget ?? .skipped) }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func toggle(_ setId: String) {
        if chosen.contains(setId) { chosen.remove(setId) } else { chosen.insert(setId) }
    }

    /// Goals are written on the way out, not per tap: `SetGoalsModel.toggle` persists on every call,
    /// so tapping five sets would be five whole-file writes and a half-finished picker would leave
    /// goals behind if the user backed out.
    private func finish(_ answer: DiscoverBudget) {
        for setId in chosen.sorted() where !(goals?.isCollecting(setId) ?? false) {
            goals?.toggle(setId)
        }
        AppConfig.discoverBudget = answer
        onDone()
    }
}
