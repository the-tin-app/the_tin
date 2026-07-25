import Foundation

/// What the tin already knows about a card the scanner just identified: how many physical copies
/// you already hold, and whether you're hunting it.
///
/// The scanner used to answer "what is this card worth" and nothing else — so the one question you
/// actually have while holding it at a bulk bin ("do I need this?") could only be answered by
/// leaving the camera and searching the tin. Card detail grew an owned strip on 2026-07-24; this
/// is the same answer, delivered at the moment of the lock.
struct ScanKnowledge: Equatable {
    /// Physical copies already in the tin (Σ qty across every entry for this card).
    var ownedCount: Int
    var wanted: Bool

    /// Whether there's anything worth saying at all — a card you neither own nor want stays quiet.
    var isNotable: Bool { ownedCount > 0 || wanted }

    /// "On your wishlist · you own 2" — nil when there's nothing to say. Wishlist leads: it's the
    /// reason to buy, where the owned count is usually the reason not to.
    var caption: String? {
        var parts: [String] = []
        if wanted { parts.append("On your wishlist") }
        if ownedCount > 0 { parts.append("You own \(ownedCount)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func of(cardId: String, entries: [CollectionEntry], wanted: Set<String>) -> ScanKnowledge {
        ScanKnowledge(ownedCount: entries.filter { $0.cardId == cardId }.cardCount,
                      wanted: wanted.contains(cardId))
    }
}
