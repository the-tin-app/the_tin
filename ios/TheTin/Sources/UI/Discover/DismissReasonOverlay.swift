import SwiftUI

/// The "why not this one?" panel: a dark scrim over **the card itself**, carrying the four reasons
/// and a cancel. Sized to fill whatever frame it is placed in, so the same view serves a 110pt
/// Discover tile and a 420pt deck card.
///
/// ⚠️ A `.overlay`, not a `fullScreenCover` or a `confirmationDialog`. The first cut of this was a
/// full-screen cover and it was far too heavy for a gesture used several times a minute — the
/// rejection should feel like editing the card in place, not opening a screen. (A `popover` or
/// `confirmationDialog` would also need an anchor on iPad, which has failed repeatedly here — see
/// the `ShareLink` note in CLAUDE.md.)
///
/// **2×2, not a 4-row list**, for the same reason: a card is portrait but not *that* portrait, and
/// four stacked rows inside a 110×153pt tile leaves ~28pt per row. A grid matches the shape.
struct DismissReasonOverlay: View {
    /// Compact drops the icons and shrinks the type — the Discover home tile, where the whole panel
    /// is about 110pt across.
    var compact: Bool = false
    let onChoose: (DismissReason) -> Void
    let onCancel: () -> Void

    private var rows: [[DismissReason]] {
        let all = DismissReason.allCases
        return [Array(all.prefix(2)), Array(all.dropFirst(2))]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.78)

            VStack(spacing: compact ? 3 : 8) {
                if !compact {
                    Text("Why not this one?")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: compact ? 3 : 8) {
                        ForEach(row) { reason in button(reason) }
                    }
                }
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(compact ? .caption2 : .footnote)
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.vertical, compact ? 2 : 4)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(compact ? 5 : 12)
        }
        // Matches CardImageView's corner treatment so the scrim sits ON the card, not in a box
        // around it.
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 12))
        .transition(.opacity)
    }

    private func button(_ reason: DismissReason) -> some View {
        Button { onChoose(reason) } label: {
            VStack(spacing: compact ? 1 : 4) {
                if !compact {
                    Image(systemName: reason.systemImage).font(.title3)
                }
                Text(reason.shortLabel)
                    .font(compact ? .system(size: 9, weight: .semibold) : .caption.bold())
                    .multilineTextAlignment(.center)
                    // The labels are already two lines; scaling covers Dynamic Type and the
                    // narrowest tile without truncating a word to nothing.
                    .minimumScaleFactor(0.6)
                    .lineLimit(2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, compact ? 4 : 10)
            .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: compact ? 4 : 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reason.label)
        .accessibilityHint(reason.effect)
    }
}
