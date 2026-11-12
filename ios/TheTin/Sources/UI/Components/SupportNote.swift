import SwiftUI

/// The one tip note. Sits inside a screen's own content (a list row or a stack child), shows only
/// while `SupportPromptModel.current` is this screen's moment, and goes away when the screen does.
///
/// Honest about money, quiet about everything else: no counter, no progress bar, no "supporter"
/// anything. The ✕ is a real no and the model treats it as one.
struct SupportNote: View {
    let moment: SupportMoment
    @Environment(SupportPromptModel.self) private var prompt: SupportPromptModel?
    @State private var showingTipJar = false

    var body: some View {
        if let prompt, prompt.current == moment {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(moment.lead).font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Button { prompt.dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
                    .padding(.trailing, -12).padding(.top, -12)
                }
                Text("The Tin is free and nothing is ever locked, but it costs about \(SupportCosts.totalText) to run — mostly card price data. Tips keep it going and fund what's next.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("See where it goes") { showingTipJar = true }
                    .font(.footnote.weight(.semibold))
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .sheet(isPresented: $showingTipJar) {
                NavigationStack {
                    TipJarView(model: prompt.tipJar)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingTipJar = false } } }
                }
            }
        }
    }
}

extension View {
    /// Offers `moment` once `condition` holds, and withdraws it when the screen goes away.
    func supportMoment(_ moment: SupportMoment, when condition: Bool) -> some View {
        modifier(SupportMomentModifier(moment: moment, condition: condition))
    }
}

private struct SupportMomentModifier: ViewModifier {
    let moment: SupportMoment
    let condition: Bool
    @Environment(SupportPromptModel.self) private var prompt: SupportPromptModel?

    func body(content: Content) -> some View {
        content
            .task(id: condition) { if condition { await prompt?.offer(moment) } }
            .onDisappear { prompt?.leave(moment) }
    }
}
