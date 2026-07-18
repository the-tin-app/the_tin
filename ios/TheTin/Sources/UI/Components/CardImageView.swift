import SwiftUI
import UIKit

/// Card art loaded through the durable `ImageCache` (offline after first view); NULL image_base
/// or a load failure falls back to a placeholder with set/number text (spec §6, contract §3.3).
/// `card` is optional so callers with no representative card (e.g. a set with a null `repCardId`)
/// can render a generic placeholder tile without a crash.
struct CardImageView: View {
    let card: CardRecord?
    let quality: String // "low" for grids, "high" for detail
    @State private var image: Image?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let card {
                loaded(card)
                    .task(id: card.imageURL(quality: quality)) { await load(card) }
            } else {
                placeholder(for: nil)
            }
        }
        .aspectRatio(0.717, contentMode: .fit) // standard card ratio
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func loaded(_ card: CardRecord) -> some View {
        if let image {
            image.resizable().aspectRatio(contentMode: .fit)
                .transition(.opacity) // cross-fades in over the placeholder instead of popping
        } else {
            placeholder(for: card)
        }
    }

    private func load(_ card: CardRecord) async {
        image = nil
        guard let url = card.imageURL(quality: quality),
              let data = await ImageCache.shared.image(for: url) else { return }
        let decoded = await Task.detached(priority: .utility) { UIImage(data: data) }.value
        guard let decoded, !Task.isCancelled else { return }
        if reduceMotion {
            image = Image(uiImage: decoded)
        } else {
            withAnimation(.easeOut(duration: 0.25)) { image = Image(uiImage: decoded) }
        }
    }

    private func placeholder(for card: CardRecord?) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .overlay {
                if let card {
                    if quality == "high" {
                        matchInfo(card)
                    } else {
                        VStack(spacing: 2) {
                            Text(card.setId.uppercased()).font(.caption2.bold())
                            Text("#\(card.number)").font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
    }

    /// Detail-size fallback when no art exists: the card's printed facts (name, HP, types,
    /// moves + damage, rarity/artist) so the user can match the physical card in hand.
    private func matchInfo(_ card: CardRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.name).font(.subheadline.bold()).lineLimit(2)
                Spacer(minLength: 4)
                if let hp = card.hp { Text("HP \(hp)").font(.caption.bold()) }
            }
            if !card.types.isEmpty {
                Text(card.types.joined(separator: " · ")).font(.caption2)
            }
            ForEach(Array(card.attacks.enumerated()), id: \.offset) { _, attack in
                HStack(alignment: .firstTextBaseline) {
                    Text(attack.name).font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    if let damage = attack.damage { Text(damage).font(.caption.bold()) }
                }
            }
            Spacer(minLength: 0)
            let credits = [card.rarity, card.artist].compactMap { $0 }
            if !credits.isEmpty {
                Text(credits.joined(separator: " · ")).font(.caption2).lineLimit(1)
            }
            Text("\(card.setId.uppercased()) #\(card.number)").font(.caption2.bold())
        }
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .minimumScaleFactor(0.7)
    }
}
