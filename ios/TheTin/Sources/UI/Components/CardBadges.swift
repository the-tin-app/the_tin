import SwiftUI

struct CardBadges: View {
    let owned: Bool
    let wanted: Bool
    var body: some View {
        HStack(spacing: 3) {
            if owned { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            if wanted { Image(systemName: "heart.fill").foregroundStyle(.pink) }
        }
        .font(.caption2)
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([owned ? "In your tin" : nil, wanted ? "On your wishlist" : nil]
            .compactMap(\.self).joined(separator: ", "))
    }
}
