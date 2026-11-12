import SwiftUI

/// Settings → Support → Leave a tip.
///
/// Reachable from Settings and from the few earned `SupportNote`s, never from a feed, a card or a
/// launch — the app's pitch is "no ads", and a prompt is an ad for ourselves. There is no meter
/// of what a person has given and no "supporter" state anywhere: the tip is a thank-you and
/// changes nothing in the app.
///
/// Layout: the story in two lines, the amounts as real buttons (full-contrast prices — secondary
/// text inside a tinted button read as *disabled*), the monthly option set apart, and the honest
/// cost breakdown underneath for whoever wants to check the ask.
struct TipJarView: View {
    let model: TipJarModel

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "heart.fill").font(.largeTitle).foregroundStyle(.pink) // contrast-ok: glyph
                    Text("Keep The Tin running")
                        .font(.title3.weight(.semibold))
                    Text("The Tin is free and nothing in it is ever locked — tipping or not, it works the same. Tips pay the bills and fund what gets built next.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            }

            switch model.state {
            case .idle, .loading:
                Section { HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) } }
            case .unavailable:
                Section { Text("Tips aren't available right now.").foregroundStyle(.secondary) }
            case .ready(let options):
                optionsSection(options)
            }

            if let banner = model.banner {
                Section {
                    switch banner {
                    case .thanks:
                        Label("Thank you — that genuinely helps.", systemImage: "heart.fill")
                            .foregroundStyle(.pink)
                    case .failed:
                        Text("That didn't go through, and you haven't been charged. Try again in a moment.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(SupportCosts.lines, id: \.name) { line in
                    LabeledContent(line.name, value: line.amount)
                }
                LabeledContent("Total, about") { Text(SupportCosts.totalText).fontWeight(.semibold) }
            } header: {
                Text("Where it goes")
            } footer: {
                Text("With enough supporters there's a good roadmap of new features to build. Until then this just keeps the lights on.")
            }
        }
        .navigationTitle("Leave a tip")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    // MARK: Options

    @ViewBuilder private func optionsSection(_ options: [TipOption]) -> some View {
        let once = options.filter { !$0.isRecurring }
        let monthly = options.filter(\.isRecurring)
        if !once.isEmpty {
            Section {
                HStack(spacing: 10) {
                    ForEach(Array(once.enumerated()), id: \.element.id) { index, option in
                        amountButton(option, prominent: once.count == 3 && index == 1)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } header: {
                Text("One time")
            }
        }
        if !monthly.isEmpty {
            Section {
                ForEach(monthly) { option in
                    Button { Task { await model.tip(option) } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(option.price) every month").font(.body.weight(.semibold))
                                Text("Cancel any time in your Apple ID subscriptions.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.purchasing == option.id { ProgressView() }
                        }
                        .contentShape(Rectangle())
                    }
                    .tint(.primary)
                    .disabled(model.purchasing != nil)
                }
            } header: {
                Text("Or monthly")
            } footer: {
                Text("Monthly tips are the biggest help — they cover the recurring bills.")
            }
        }
    }

    private func amountButton(_ option: TipOption, prominent: Bool) -> some View {
        let button = Button { Task { await model.tip(option) } } label: {
            VStack(spacing: 2) {
                if model.purchasing == option.id {
                    ProgressView()
                } else {
                    Text(option.price).font(.title3.weight(.semibold))
                }
                Text(shortTitle(option)).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .disabled(model.purchasing != nil)
        return Group {
            if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
        }
    }

    /// "Small Tip" → "Small": the section header already says what this is.
    private func shortTitle(_ option: TipOption) -> String {
        option.title.replacingOccurrences(of: " Tip", with: "")
    }
}
