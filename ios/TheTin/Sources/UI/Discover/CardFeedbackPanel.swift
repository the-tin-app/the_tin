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

    private let columns = [GridItem(.flexible(), spacing: PanelMetrics.columnSpacing),
                           GridItem(.flexible(), spacing: PanelMetrics.columnSpacing)]

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

            LazyVGrid(columns: columns, spacing: PanelMetrics.columnSpacing) {
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
                                // ⚠️ `lineLimit(2)`, and it is load-bearing at GRID density —
                                // together with the chrome sizes in `PanelMetrics`, which is where
                                // the widths are worked out.
                                //
                                // This panel ships at wildly different widths: ~420pt over the 1-up
                                // deck, down to a 62.75pt chip in a grid cell on a 375pt phone.
                                // "Less from this generation" has never fitted one line at any
                                // legible size, so it truncated to "Less from this ge…" — cutting
                                // the tune-vs-hide distinction this line exists to make.
                                //
                                // It was invisible because the text was 9pt grey. Rendering it at
                                // `.caption2` did not cause the truncation — measured, both ways —
                                // it just made it big enough to notice.
                                //
                                // Wrapping rather than shortening the copy: the grid card is taller
                                // than the panel at every width, so the second line is free, and the
                                // deck fits every string on one line and is unchanged.
                                Text(effect)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
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
        .padding(PanelMetrics.innerPadding)
        // No `.shadow()` — the Flat Tin Rule reserves those for card art, and this panel floats
        // over exactly that. `.regularMaterial` already separates it from the art underneath;
        // the shadow only made it read as a web card sitting on top of one.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        // Inset on purpose — see the header. A full-bleed panel is what ate the deck's swipe.
        .padding(.horizontal, PanelMetrics.outerPadding)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

/// The feedback panel's chrome, as named constants because `DiscoverFeedbackTests` derives the
/// chip width from them — so changing one re-runs the truncation check instead of silently
/// invalidating it.
///
/// ⚠️ **The narrowest chip this panel ships is 56.75pt, and it is not the one you develop on.**
/// The panel's tightest home is a grid cell on a 375pt phone — iPhone SE 2nd/3rd gen, 13 mini,
/// XS, all supported by the iOS 17 target: `(375 − 40 grid padding − 16 grid spacing) / 2 =
/// 159.5pt`, less this padding, split across two columns. A Pro Max gives 73pt, nearly 30% more,
/// which is why a caption that truncates on half the fleet can look perfect while you build it.
///
/// The values are unchanged; they are named rather than inline so the test cannot drift from them.
///
/// A separate `enum` because `CardFeedbackPanel` is generic, and Swift has no static stored
/// properties in generic types.
enum PanelMetrics {
    static let outerPadding: CGFloat = 10
    static let innerPadding: CGFloat = 10
    static let columnSpacing: CGFloat = 6
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
