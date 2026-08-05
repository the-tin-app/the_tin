import SwiftUI

/// The "why not this one?" sheet behind the thumbs-down: the card, dimmed, over four one-tap
/// reasons plus a plain hide.
///
/// ⚠️ A `fullScreenCover`, **not** a `confirmationDialog` or a `popover`. Both of those need an
/// anchor on iPad, and this project has a long history of anchored presentations rendering as a
/// tiny uninteractable card or simply never opening (see the `ShareLink` note in CLAUDE.md — four
/// plausible causes were reproduced and ruled out before the fix turned out to be "stop using an
/// anchored presentation"). A cover has no anchor to get wrong and behaves identically on both
/// devices.
struct DismissReasonOverlay: View {
    let card: CardRecord
    /// `nil` reason = "just hide this one", which tunes nothing.
    let onChoose: (DismissReason?) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()
                // Tap anywhere off the panel to back out. A rejection the user didn't mean is
                // worse than one they have to repeat.
                .onTapGesture(perform: onCancel)

            VStack(spacing: 20) {
                CardImageView(card: card, quality: "low")
                    .frame(maxWidth: 150)
                    .opacity(0.45)
                    .accessibilityHidden(true)

                VStack(spacing: 4) {
                    Text("Why not this one?").font(.title3.bold())
                    Text("This tunes what you see next")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    ForEach(DismissReason.allCases) { reason in
                        Button { onChoose(reason) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: reason.systemImage)
                                    .font(.title3)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(reason.label).font(.body.weight(.medium))
                                    // Saying what each answer DOES keeps the gesture from being a
                                    // black box — the user is tuning a system, not voting.
                                    Text(reason.effect)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 24) {
                    Button("Just hide it") { onChoose(nil) }
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                .font(.subheadline)
                .padding(.top, 4)
            }
            // Capped so the panel doesn't stretch across an iPad — an 1100pt-wide row of buttons
            // is the same mistake `StreamView.page` already documents for card art.
            .frame(maxWidth: 380)
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }
}
