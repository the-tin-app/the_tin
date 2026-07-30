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
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                if let count { Text("\(count)").fontWeight(.semibold).monospacedDigit() }
            }
            if wanted { Image(systemName: "heart.fill").foregroundStyle(.pink) }
        }
        .font(.caption2)
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([ownedLabel, wanted ? "On your wishlist" : nil]
            .compactMap(\.self).joined(separator: ", "))
    }
}
