import SwiftUI

/// Asked once, the first time For You has nothing to go on — and reopenable from Settings.
///
/// ⚠️ **It asks about price and nothing else.** An earlier version also asked which sets you were
/// collecting; that was removed at Tomas's call for 4.1(a) reasons. This is the first screen a new
/// user meets and therefore the first screen an App Review reviewer meets, and a list of product
/// names on it reads as an official product. A price question names nothing. Set goals still drive
/// the top rows of For You — they are just set from a set screen instead.
///
/// ⚠️ **Two thresholds, not three ranges.** Stated as ranges ("$1–10", "$30–60") a $20 card belongs
/// to no tier and the app has to guess silently. Two cut-off points partition the catalog with
/// nothing falling through, while still reading as the three sentences a collector would say.
struct ForYouSeedView: View {
    var initial: PriceTiers? = nil
    let onDone: () -> Void

    @State private var routine: Double = PriceTiers.default.routineCeiling
    @State private var occasional: Double = PriceTiers.default.occasionalCeiling

    /// Only the choices above the routine line: offering "$30" as an occasional ceiling when the
    /// routine ceiling is already $50 would let the user state something incoherent.
    private var occasionalChoices: [Double] {
        PriceTiers.choicesOccasional.filter { $0 > routine }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    amountRow(choices: PriceTiers.choicesRoutine, selection: $routine)
                } header: {
                    Text("I'd buy one without thinking, up to")
                } footer: {
                    Text("These fill your \"Easy adds\" row.")
                }

                Section {
                    amountRow(choices: occasionalChoices, selection: $occasional)
                } header: {
                    Text("Now and then, I'd go up to")
                } footer: {
                    Text("A treat rather than a habit — your \"Worth a think\" row.")
                }

                Section {
                    // The third tier needs no number: it is everything above the second line. Saying
                    // so plainly is also the promise that expensive cards are NOT being hidden.
                    Label {
                        Text("Above \(money(occasional)) — **someday**. Still shown, in their own row.")
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Text("You can change these any time in Settings. Once you've recorded a few purchases, For You uses what you actually paid instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Set up For You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Skip still STORES a value — the defaults. That is what makes "have we asked?"
                    // a single nil check with no second bookkeeping flag beside it.
                    Button("Skip") { save(PriceTiers.default) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save(PriceTiers(routineCeiling: routine, occasionalCeiling: occasional))
                    }
                }
            }
            .onAppear {
                guard let initial else { return }
                routine = initial.routineCeiling
                occasional = initial.occasionalCeiling
            }
            .onChange(of: routine) { _, new in
                // Keep the two lines coherent: raising the first past the second drags the second up.
                if occasional <= new { occasional = occasionalChoices.first ?? new * 4 }
            }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func amountRow(choices: [Double], selection: Binding<Double>) -> some View {
        // A segmented picker rather than a keypad: a decimal-pad TextField has no return key, so in
        // a Form there is no way to dismiss it without a keyboard toolbar — a bad first screen.
        Picker("", selection: selection) {
            ForEach(choices, id: \.self) { amount in
                Text(money(amount)).tag(amount)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func money(_ amount: Double) -> String { "$\(Int(amount.rounded()))" }

    private func save(_ tiers: PriceTiers) {
        AppConfig.priceTiers = tiers
        onDone()
    }
}
