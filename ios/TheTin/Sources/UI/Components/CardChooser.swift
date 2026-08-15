import SwiftUI

/// "Which of these is it?" — a dark bottom sheet with a 2×2 grid of card images, each with its name
/// and "Set · Year · #num/total", plus an escape hatch.
///
/// Variant A, approved 2026-07-15, and the most load-bearing interaction in both scanning surfaces:
/// over 346 binder cells the four tiles contained the true card **48 times out of 48**. Tap-to-resolve
/// is a near-guaranteed path, not a fallback — which is why the gate that feeds it is allowed to
/// withhold a lock rather than guess.
///
/// ⚠️ It takes `options` and two closures, NOT a model. It used to be `AmbiguousChooser(model:
/// ScanModel)` inside `ScanView`, which is what kept the virtual binder from reusing it: a view that
/// shows four tiles has no business knowing what a scan session is. `escape` is the wording, because
/// the two callers mean genuinely different things by "none of these" — the live scanner resumes
/// scanning, the binder goes to manual entry.
struct CardChooser: View {
    let options: [ChooserOption]
    var escape: String = "None of these"
    let onPick: (String) -> Void
    let onEscape: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(options) { option in
                    Button { onPick(option.id) } label: {
                        VStack(spacing: 6) {
                            CardImageView(card: option.card, quality: "low")
                                .frame(maxWidth: 96)
                            VStack(spacing: 1) {
                                Text(option.card?.name ?? option.id)
                                    .font(.caption.bold()).foregroundStyle(.white)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                Text(option.caption)
                                    .font(.caption2).foregroundStyle(.white.opacity(0.65))
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button(action: onEscape) {
                Text(escape)
                    .font(.footnote.weight(.medium)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.28)))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 20))
    }
}
