import SwiftUI

/// Brand palette for the tin — the app icon's blue metal and the card inside it.
private extension Color {
    static let tinLight = Color(red: 0.23, green: 0.45, blue: 0.79) // #3b74c9
    static let tinLidHi = Color(red: 0.36, green: 0.56, blue: 0.87) // #5d90dd
    static let tinDark = Color(red: 0.09, green: 0.22, blue: 0.44)  // #16386f
    static let tinCardHi = Color(red: 0.93, green: 0.73, blue: 0.38) // #eebb62
    static let tinCardLo = Color(red: 0.85, green: 0.62, blue: 0.24) // #d99f3d
}

/// Small tin glyph for rows, labels, and empty states. Inherits the current
/// foreground style so call sites choose the color.
struct TinIcon: View {
    var size: CGFloat = 20

    var body: some View {
        VStack(spacing: size * 0.08) {
            RoundedRectangle(cornerRadius: size * 0.12)
                .frame(width: size, height: size * 0.2)
            RoundedRectangle(cornerRadius: size * 0.16)
                .frame(width: size * 0.8, height: size * 0.52)
        }
        .accessibilityHidden(true)
    }
}

/// The two values that move during the loading loop: how far the card sits out of
/// the tin, and how far the lid is tilted open.
private struct TinPose {
    var cardY: CGFloat = 4    // resting inside the tin (hidden behind the body)
    var lidAngle: Double = 0  // flat / closed
}

/// The tin plays a full open→emerge→return→close loop while loading: lid tilts
/// back, a card rises fully out, drops back in, and the lid settles shut — then
/// repeats. Replaces `ProgressView` at the app's main loading moments.
struct TinLoadingView: View {
    var label: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if reduceMotion {
                    tin(pose: TinPose(cardY: -28, lidAngle: -26)) // static open tin, no motion
                } else {
                    KeyframeAnimator(initialValue: TinPose(), repeating: true) { pose in
                        tin(pose: pose)
                    } keyframes: { _ in
                        // Lid: open, hold while the card moves, close, hold shut. (Σ = 2.8s)
                        KeyframeTrack(\.lidAngle) {
                            CubicKeyframe(-26, duration: 0.5)
                            CubicKeyframe(-26, duration: 1.5)
                            CubicKeyframe(0, duration: 0.5)
                            CubicKeyframe(0, duration: 0.3)
                        }
                        // Card: stay in during open, rise fully out, hold, drop back in, stay in
                        // while the lid closes. (Σ = 2.8s — must match the lid track.)
                        KeyframeTrack(\.cardY) {
                            CubicKeyframe(4, duration: 0.5)
                            CubicKeyframe(-28, duration: 0.6)
                            CubicKeyframe(-28, duration: 0.3)
                            CubicKeyframe(4, duration: 0.6)
                            CubicKeyframe(4, duration: 0.8)
                        }
                    }
                }
            }
            .frame(width: 110, height: 90)
            if let label {
                Text(label).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? String(localized: "Loading"))
    }

    /// The tin drawn at a given pose. Card is first (behind the body) so it's hidden
    /// when resting inside and only shows once it rises above the body rim.
    private func tin(pose: TinPose) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [.tinCardHi, .tinCardLo],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 34, height: 46)
                .offset(y: pose.cardY)
            RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(colors: [.tinLight, .tinDark],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 84, height: 44)
                .offset(y: 14)
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [.tinLidHi, .tinLight],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 92, height: 14)
                .rotationEffect(.degrees(pose.lidAngle), anchor: .bottomLeading)
                .offset(y: -14)
        }
    }
}
