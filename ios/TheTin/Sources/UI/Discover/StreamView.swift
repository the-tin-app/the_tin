import SwiftUI

/// Immersive full-screen "See all" deck for a Discover stream. A horizontal paging `ScrollView`
/// swipes one big card at a time; a double tap toggles Want, press-and-hold offers "Add to
/// group…", and the deck prefetches more pages as you near the end. The nav-bar back button is
/// automatic (this is a pushed view).
///
/// Uses a paging `ScrollView` + `LazyHStack` rather than `TabView(.page)`: the deck is a dynamic,
/// appending list (prefetch grows `pager.cards` as you swipe), and `TabView(.page)` sticks/settles
/// between pages when its `ForEach` mutates mid-swipe. `ScrollView` + `LazyHStack` is built for
/// lazy, appendable content and doesn't fight the pan. Want is a DOUBLE tap so a single-tap
/// recognizer can't compete with the swipe either.
struct StreamView: View {
    let kind: DiscoverModel.StreamKind
    let model: DiscoverModel
    var wants: WantsModel?
    var collection: CollectionModel?

    @State private var pager: StreamPager?
    @State private var currentIndex: Int?
    @State private var sheetCard: CardRecord?
    @State private var prefetcher = CardImagePrefetcher()
    @State private var wantBump = 0 // bumped on each double-tap to fire the haptic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let pager, !pager.cards.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(pager.cards.enumerated()), id: \.offset) { index, card in
                            page(for: card)
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentIndex)
                .scrollIndicators(.hidden)
                .overlay { chevrons } // fixed affordance — never scrolls with a page, never doubles
            } else {
                TinLoadingView(label: "Loading \(kind.title)…")
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if pager == nil {
                pager = StreamPager(stream: model.makeStream(kind))
                await pager?.loadNextPage()
                prefetchAround(0)
            }
        }
        .onChange(of: currentIndex) {
            guard let i = currentIndex, let pager else { return }
            prefetchAround(i)
            if i >= pager.cards.count - 3 {
                Task { await pager.loadNextPage(); prefetchAround(i) }
            }
        }
        .sheet(item: $sheetCard) { card in
            if let collection {
                NavigationStack {
                    EntryFormView(card: card, groups: collection.groups, existing: nil,
                                  matrix: collection.matrixByCard[card.id] ?? [],
                                  onCreateGroup: { await collection.createGroup(name: $0) }) { entry in
                        await collection.saveEntry(entry)
                    }
                }
            }
        }
    }

    /// Warm the next several cards' high-res art so it's cached before the swipe reaches them.
    private func prefetchAround(_ index: Int) {
        guard let pager else { return }
        let end = min(index + 5, pager.cards.count)
        guard index < end else { return }
        let urls = pager.cards[index..<end].compactMap { $0.imageURL(quality: "high") }
        prefetcher.prefetch(urls)
    }

    @ViewBuilder
    private func page(for card: CardRecord) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            CardImageView(card: card, quality: "high")
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40)
                .overlay(alignment: .topTrailing) { heart(for: card) }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    wants?.toggle(card.id)
                    wantBump += 1
                }
                .sensoryFeedback(.impact, trigger: wantBump)
                .contextMenu {
                    if collection != nil {
                        Button {
                            sheetCard = card
                        } label: {
                            Label("Save to tin…", systemImage: "plus.square.on.square")
                        }
                    }
                }

            VStack(spacing: 4) {
                Text(card.name).font(.title3.bold()).multilineTextAlignment(.center)
                PriceLabel(value: try? model.store.price(cardId: card.id)?.rawUsd)
                if let why = model.caption(for: card, kind: kind) {
                    Text(why).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal)
            Spacer(minLength: 0)
        }
    }

    /// Faint ‹ › affordance signalling the deck swipes horizontally. Fixed to the deck, not a page.
    private var chevrons: some View {
        HStack {
            Image(systemName: "chevron.left")
            Spacer()
            Image(systemName: "chevron.right")
        }
        .font(.title2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A real button (not just a double-tap echo): the only VoiceOver-reachable Want control
    /// on this screen, and the visible affordance for everyone else. Double tap stays as the
    /// power-user shortcut.
    @ViewBuilder
    private func heart(for card: CardRecord) -> some View {
        if let wants {
            Button {
                wants.toggle(card.id)
                wantBump += 1
            } label: {
                Image(systemName: wants.isWanted(card.id) ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(wants.isWanted(card.id) ? .red : .secondary)
                    .padding(8)
                    .background(.thinMaterial, in: Circle())
                    // Pops the heart when this card's want-state flips (add or remove).
                    // Reduce Motion: value pinned false, so the bounce never triggers.
                    .symbolEffect(.bounce, value: reduceMotion ? false : wants.isWanted(card.id))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(12)
            .animation(reduceMotion ? nil : .snappy, value: wants.isWanted(card.id))
            .accessibilityLabel(wants.isWanted(card.id) ? "Remove from wishlist" : "Add to wishlist")
        }
    }
}
