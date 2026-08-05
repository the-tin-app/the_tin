import SwiftUI

/// The state a card sits in once it has been rejected: dimmed, saying what was recorded, with a way
/// back. Without it a thumbs-down just made the card vanish, which reads as "nothing happened"
/// rather than "got it" — the feedback was captured and the UI never said so.
struct DismissConfirmedOverlay: View {
    var compact: Bool = false
    /// `nil` when the card was hidden without a stated reason.
    let reason: DismissReason?
    let onUndo: () -> Void

    var body: some View {
        ZStack {
            // ⚠️ Heavy on purpose. At 0.72 the card art bled through and the labels fought it —
            // full-art cards are bright and busy, which is exactly what this sits on top of.
            Color.black.opacity(0.88)
            VStack(spacing: compact ? 3 : 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(compact ? .title3 : .largeTitle)
                    .foregroundStyle(.white)
                Text(reason?.effect ?? "Hidden")
                    .font(compact ? .system(size: 9, weight: .semibold) : .caption.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .lineLimit(3)
                Button(action: onUndo) {
                    Text("Undo")
                        .font(compact ? .system(size: 10, weight: .bold) : .footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, compact ? 8 : 14)
                        .padding(.vertical, compact ? 3 : 6)
                        .background(.white.opacity(0.22), in: Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(compact ? 5 : 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(reason.map { "Noted: \($0.effect)" } ?? "Card hidden")
    }
}

/// The "why not this one?" panel: a dark scrim over **the card itself**, carrying the four reasons
/// and a cancel. Sized to fill whatever frame it is placed in.
///
/// ⚠️ A `.overlay`, not a `fullScreenCover` or a `confirmationDialog`. The first cut was a
/// full-screen cover and it was far too heavy for a gesture used several times a minute — the
/// rejection should feel like editing the card in place, not opening a screen. (A `popover` or
/// `confirmationDialog` would also need an anchor on iPad, which has failed repeatedly here — see
/// the `ShareLink` note in CLAUDE.md.)
///
/// **2×2, not a 4-row list**: a card is portrait but not *that* portrait, and four stacked rows
/// inside the smallest frame this appears in leaves ~28pt per row. A grid matches the shape.
///
/// ⚠️ **For You only.** `dismissed` is passed to `ForYouStream` and nothing else, so offering this
/// on a Full-art or Chase card would promise a change to a row it cannot touch.
struct DismissReasonOverlay: View {
    /// Compact drops the icons and shrinks the type — used by the deck's 2×2 grid density, where a
    /// cell is a fraction of the 1-up card.
    var compact: Bool = false
    let onChoose: (DismissReason) -> Void
    let onCancel: () -> Void

    private var rows: [[DismissReason]] {
        let all = DismissReason.allCases
        return [Array(all.prefix(2)), Array(all.dropFirst(2))]
    }

    var body: some View {
        ZStack {
            // ⚠️ Heavy on purpose — see DismissConfirmedOverlay. At 0.78 "Wrong era" was
            // unreadable over a bright card.
            Color.black.opacity(0.9)

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
            .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: compact ? 4 : 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reason.label)
        .accessibilityHint(reason.effect)
    }
}
