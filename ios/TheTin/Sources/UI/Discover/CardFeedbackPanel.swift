import SwiftUI

/// The 2×2 panel that appears over a card after you act on it.
///
/// One component for both gestures, because they share a principle: **the action happens
/// immediately and the refinement is optional.** Thumbing down hides the card at once and then
/// offers a reason; hearting adds it at Normal at once and then offers a priority. Ignore either
/// panel and what you did still stands.
///
/// ⚠️ This replaces `DismissReasonOverlay`, which was deliberately left behind in the rework: it had
/// been through five revisions and carried two bugs worth not repeating —
///
/// 1. It was applied **before** `.contentShape` / `.onTapGesture` / `.contextMenu`, which wrap what
///    precedes them and take the touch first. Not one button responded, not even Cancel. A small
///    corner badge slips past that; a full-bleed panel does not.
/// 2. Hoisting it above the gesture chain then ate the deck's horizontal pan, because `Text` and
///    `Image` are hit-testable in SwiftUI — exempting only the scrim is not enough.
///
/// So this panel is deliberately **inset, not full-bleed**, and every interactive element is a real
/// `Button`. It must be attached ABOVE any gesture modifiers on the card.
struct CardFeedbackPanel<Option: Identifiable & Equatable>: View {
    let title: String
    let options: [Option]
    let label: (Option) -> String
    let systemImage: (Option) -> String
    let effect: (Option) -> String?
    /// Marked so the current value reads as chosen — the heart's Normal default, mainly.
    var selected: Option?
    let onPick: (Option) -> Void
    let onDismiss: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close")
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(options) { option in
                    Button { onPick(option) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: systemImage(option)).font(.subheadline)
                            Text(label(option))
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                            if let effect = effect(option) {
                                Text(effect)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(selected == option ? AnyShapeStyle(.tint.opacity(0.18))
                                                       : AnyShapeStyle(.quaternary),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected == option ? .isSelected : [])
                }
            }
        }
        .padding(10)
        // No `.shadow()` — the Flat Tin Rule reserves those for card art, and this panel floats
        // over exactly that. `.regularMaterial` already separates it from the art underneath;
        // the shadow only made it read as a web card sitting on top of one.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        // Inset on purpose — see the header. A full-bleed panel is what ate the deck's swipe.
        .padding(.horizontal, 10)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

/// Priority as offered on the heart panel: the full scale, Grail included.
///
/// ⚠️ Ordered strongest-first so the 2×2 grid reads Grail · High / Normal · Low — the two you reach
/// for most often are not the two hardest to hit.
extension WantPriority {
    static var panelOrder: [WantPriority] { [.grail, .high, .normal, .low] }

    var panelLabel: String {
        switch self {
        case .grail:  return "Grail"
        case .high:   return "High"
        case .normal: return "Normal"
        case .low:    return "Low"
        }
    }

    var panelImage: String {
        switch self {
        case .grail:  return "crown"
        case .high:   return "arrow.up.circle"
        case .normal: return "circle"
        case .low:    return "arrow.down.circle"
        }
    }
}
