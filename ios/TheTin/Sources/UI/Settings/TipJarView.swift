import SwiftUI

/// Settings → Support → Leave a tip.
///
/// Reachable only from Settings, never from a feed, a card or a launch — the app's pitch is "no
/// ads", and a prompt is an ad for ourselves. There is no meter of what a person has given and no
/// "supporter" state anywhere: the tip is a thank-you and changes nothing in the app.
struct TipJarView: View {
    let model: TipJarModel

    var body: some View {
        List {
            Section {
                Text("The Tin is free and nothing in it is ever locked — tipping or not, it works the same. It does cost money to run, and that's what tips cover:")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(SupportCosts.lines, id: \.name) { line in
                    LabeledContent(line.name, value: line.amount)
                        .font(.footnote)
                }
                LabeledContent("About", value: SupportCosts.totalText).font(.footnote.weight(.semibold))
            } header: {
                Text("Where it goes")
            } footer: {
                Text("With enough supporters there's a good roadmap of new features to build. Until then this just keeps the lights on.")
            }
            Section {
                switch model.state {
                case .idle, .loading:
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                case .unavailable:
                    Text("Tips aren't available right now.").foregroundStyle(.secondary)
                case .ready(let options):
                    ForEach(options) { option in
                        Button { Task { await model.tip(option) } } label: {
                            HStack {
                                Text(label(for: option))
                                Spacer()
                                if model.purchasing == option.id {
                                    ProgressView()
                                } else {
                                    Text(option.price).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(model.purchasing != nil)
                    }
                }
            } footer: {
                if case .ready = model.state {
                    Text("One-time tips are charged once. Monthly tips renew until you cancel in your Apple ID subscriptions.")
                }
            }
            if let banner = model.banner {
                Section {
                    switch banner {
                    case .thanks: Text("Thank you — that genuinely helps. 🙏")
                    case .failed: Text("That didn't go through, and you haven't been charged. Try again in a moment.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Leave a tip")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private func label(for option: TipOption) -> String {
        option.isRecurring ? "\(option.title) · monthly" : option.title
    }
}
