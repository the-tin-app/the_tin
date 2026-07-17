import SwiftUI

/// Long-press quick actions for any card tile: toggle Wanted, or open the save sheet.
struct CardQuickActions: ViewModifier {
    let cardId: String
    var wants: WantsModel?
    var onAddToGroup: (() -> Void)?

    func body(content: Content) -> some View {
        content.contextMenu {
            if let wants {
                Button {
                    wants.toggle(cardId)
                } label: {
                    Label(wants.isWanted(cardId) ? "Remove from Wishlist" : "Add to Wishlist",
                          systemImage: wants.isWanted(cardId) ? "heart.slash" : "heart")
                }
            }
            if let onAddToGroup {
                Button {
                    onAddToGroup()
                } label: {
                    Label("Save to tin…", systemImage: "folder.badge.plus")
                }
            }
        }
    }
}

extension View {
    func cardQuickActions(cardId: String, wants: WantsModel?,
                          onAddToGroup: (() -> Void)? = nil) -> some View {
        modifier(CardQuickActions(cardId: cardId, wants: wants, onAddToGroup: onAddToGroup))
    }
}
