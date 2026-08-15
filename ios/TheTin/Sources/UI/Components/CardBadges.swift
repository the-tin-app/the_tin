import SwiftUI

struct CardBadges: View {
    let owned: Bool
    let wanted: Bool
    /// How many you own, when the number carries something the checkmark can't — sealed products
    /// come in multiples, a card is simply in the tin or not. nil keeps the plain card-tile badge.
    var count: Int? = nil

    private var ownedLabel: String? {
        guard owned else { return nil }
        return count.map { "\($0) in your tin" } ?? "In your tin"
    }

    var body: some View {
        HStack(spacing: 3) {
            if owned {
                // `.ultraThinMaterial` over CARD ART, so the backdrop is whatever the holo is
                // doing — bare `.green` measures ~2.2:1 on a light one, under even the 3:1
                // non-text floor. The heart below stays `.pink` (3.65:1), which clears it.
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.statusPositive)
                if let count { Text("\(count)").fontWeight(.semibold).monospacedDigit() }
            }
            if wanted { Image(systemName: "heart.fill").foregroundStyle(.pink) } // contrast-ok: glyph, not text
        }
        .font(.caption2)
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([ownedLabel, wanted ? "On your wishlist" : nil]
            .compactMap(\.self).joined(separator: ", "))
    }
}
