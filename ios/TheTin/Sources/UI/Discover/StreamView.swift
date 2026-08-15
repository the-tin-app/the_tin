import SwiftUI

/// Immersive full-screen "See all" deck for a Discover stream. A horizontal paging `ScrollView`
/// swipes one big card at a time; a double tap toggles Want, press-and-hold offers "Save to
/// tin…", and the deck prefetches more pages as you near the end. The nav-bar back button is
/// automatic (this is a pushed view).
///
/// Uses a paging `ScrollView` + `LazyHStack` rather than `TabView(.page)`: the deck is a dynamic,
/// appending list (prefetch grows `pager.cards` as you swipe), and `TabView(.page)` sticks/settles
/// between pages when its `ForEach` mutates mid-swipe. `ScrollView` + `LazyHStack` is built for
/// lazy, appendable content and doesn't fight the pan. Want is a DOUBLE tap so a single-tap
/// recognizer can't compete with the swipe either.
struct StreamView: View {
    let title: String
    let stream: CardStream
    let caption: (CardRecord) -> String?
    let store: CatalogStore
    var wants: WantsModel?
    var collection: CollectionModel?

    @State private var pager: StreamPager?
    @State private var currentIndex: Int?
    @State private var prefetcher = CardImagePrefetcher()
    @State private var wantBump = 0 // bumped on each double-tap to fire the haptic
    @State private var sharing: SharePayload?
    /// Which card is showing which panel. One at a time, and never both — the two gestures are
    /// mutually exclusive acts.
    @State private var panel: FeedbackPanel?

    /// Explicit feedback, when the host wired it. `nil` on Full-art / Chase / shelf decks that do
    /// not personalise, so the thumbs-down never promises tuning it cannot deliver.
    var signals: DiscoverSignalsModel?

    private enum FeedbackPanel: Equatable {
        case reason(cardId: String)
        case priority(cardId: String)

        var cardId: String {
            switch self { case .reason(let id), .priority(let id): return id }
        }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(StreamDensity.storageKey) private var densityRaw = StreamDensity.one.rawValue

    private var density: StreamDensity { StreamDensity(rawValue: densityRaw) ?? .one }

    var body: some View {
        Group {
            if let pager, !pager.cards.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(0..<density.pageCount(cardCount: pager.cards.count), id: \.self) { pageIndex in
                            pageContent(pager: pager, page: pageIndex)
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(pageIndex)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentIndex)
                .scrollIndicators(.hidden)
                .overlay { chevrons } // fixed affordance — never scrolls with a page, never doubles
            } else if let pager, pager.isEmptyResult {
                ContentUnavailableView("No cards match",
                                       systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Loosen your filters to see more."))
            } else {
                TinLoadingView(label: "Loading \(title)…")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { densityToggle }
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .task {
            if pager == nil {
                pager = StreamPager(stream: stream)
                await pager?.loadNextPage()
                prefetchAround(0)
            }
        }
        .onChange(of: currentIndex) {
            guard let i = currentIndex, let pager else { return }
            prefetchAround(i)
            // Load-more in PAGES: at 2×2 "three cards from the end" is under one screen of
            // warning and the deck runs dry mid-swipe.
            if i >= density.pageCount(cardCount: pager.cards.count) - 3 {
                Task { await pager.loadNextPage(); prefetchAround(i) }
            }
        }
    }

    /// Switching density remaps the scroll position so the card you were looking at stays on
    /// screen — see `StreamDensity.remapPage`. Written as an explicit toggle rather than a
    /// Picker: two states don't earn a segmented control in a nav bar.
    @ToolbarContentBuilder private var densityToggle: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                let old = density
                let next: StreamDensity = old == .one ? .four : .one
                if let i = currentIndex { currentIndex = next.remapPage(i, from: old) }
                densityRaw = next.rawValue
            } label: {
                // Shows the layout you'd switch TO, which is the thing the button does.
                Image(systemName: density == .one ? StreamDensity.four.symbol
                                                  : StreamDensity.one.symbol)
            }
            .accessibilityLabel(density == .one ? "Show a grid" : "Show one card")
        }
    }

    @ViewBuilder
    private func pageContent(pager: StreamPager, page: Int) -> some View {
        let range = density.cardRange(page: page, cardCount: pager.cards.count)
        if density == .one, let card = pager.cards[range].first {
            self.page(for: card)
        } else {
            gridPage(cards: Array(pager.cards[range]))
        }
    }

    /// A grid page. ⚠️ The cell art is capped for the same reason the 1-up card is: a card's
    /// aspect ratio means an uncapped width sets the HEIGHT, and two rows of ~500pt-wide cells
    /// on an iPad would be ~1400pt tall and overflow exactly as the 1-up card did. 240 keeps two
    /// rows plus their labels inside the shortest page we ship (iPhone, ~850pt usable).
    @ViewBuilder
    private func gridPage(cards: [CardRecord]) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(maximum: 240), spacing: 16,
                                                         alignment: .top),
                                     count: density.columns),
                      spacing: 16) {
                ForEach(cards) { card in gridCell(card) }
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
    }

    /// One cell. A real `NavigationLink`, not a tap gesture — it resolves on whichever stack
    /// pushed the deck (`DiscoverView` registers `CardID` for both entry points), and VoiceOver
    /// gets a link rather than an invisible gesture. Same shape as `SetDetailView`'s grid.
    ///
    /// Detail-on-single-tap exists only at this density: in 1-up the single tap is deliberately
    /// left to the deck's pan, which is why `Card details` is a real button there.
    ///
    /// ⚠️ `highPriorityGesture`, not `onTapGesture` — a plain tap gesture on a NavigationLink
    /// loses to the link and the double tap never fires. The cost, accepted knowingly: the
    /// single tap now waits out the double-tap window before the push begins.
    @ViewBuilder
    private func gridCell(_ card: CardRecord) -> some View {
        NavigationLink(value: CardID(raw: card.id)) {
            VStack(spacing: 4) {
                CardImageView(card: card, quality: "high")
                    .overlay(alignment: .topTrailing) { heart(for: card) }
                    // ⚠️ The grid needs this too, and forgetting it made the thumbs-down INVISIBLE
                    // on iPad — `StreamDensity` is `@AppStorage`, so a device left in grid mode
                    // never renders the 1-up page where the button used to live only.
                    .overlay(alignment: .topLeading) { thumbsDown(for: card) }
                    .overlay(alignment: .bottom) { feedbackPanel(for: card) }
                Text(card.name).font(.caption).lineLimit(1)
                PriceLabel(value: try? store.price(cardId: card.id)?.rawUsd)
            }
        }
        .buttonStyle(.plain)
        .highPriorityGesture(TapGesture(count: 2).onEnded {
            wants?.toggle(card.id)
            wantBump += 1
        })
        .cardQuickActions(card: card, wants: nil, collection: collection, store: store)
    }

    /// Set name for the share link's `?set=` (the web preview renders it under the card name).
    private func setName(of card: CardRecord) -> String? {
        (try? store.set(id: card.setId))?.name
    }

    /// Warm the next couple of PAGES of art so it's cached before the swipe reaches them.
    ///
    /// ⚠️ Page-denominated, and shallow on purpose. This used to be `index + 5` when a page was
    /// one card; at 2×2 that same constant would put 20 images in flight against an
    /// `ImageCache.maxConcurrentDownloads` of 4 on an A10 — the axis the Connections jetsam
    /// crash lived on. Denser pages also hold your attention longer, so they need *less*
    /// lookahead, not more.
    private func prefetchAround(_ page: Int) {
        guard let pager else { return }
        let range = density.prefetchRange(page: page, cardCount: pager.cards.count)
        guard !range.isEmpty else { return }
        let urls = pager.cards[range].compactMap { $0.imageURL(quality: "high") }
        prefetcher.prefetch(urls)
    }

    @ViewBuilder
    private func page(for card: CardRecord) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            CardImageView(card: card, quality: "high")
                // ⚠️ Capped, not `maxWidth: .infinity`. A card has a fixed aspect ratio, so an
                // uncapped width sets the HEIGHT — on an iPad the ~1080pt container made the
                // card ~1400pt tall, overflowing the screen with the top cut off and only the
                // name and price visible below it. iPhone never showed it (~430pt container
                // lands the card at ~350×490). 420 is the same cap `CardDetailView` uses for
                // its art, so a card is the same size in both places. Found on iPad 2026-08-01.
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)   // …then re-centre in the page
                .padding(.horizontal, 40)
                .overlay(alignment: .topTrailing) { heart(for: card) }
                .overlay(alignment: .topLeading) { thumbsDown(for: card) }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    wants?.toggle(card.id)
                    wantBump += 1
                }
                .sensoryFeedback(.impact, trigger: wantBump)
                // Wanted is already the double tap + heart here, so the shared menu is used for
                // its save sheet only — passing `wants: nil` keeps the long-press to one action.
                .cardQuickActions(card: card, wants: nil, collection: collection, store: store)
                // ⚠️ ABOVE the gesture modifiers, and inset rather than full-bleed. The panel this
                // replaces was applied BELOW them and not one of its buttons responded — not even
                // Cancel — because `.contentShape`/`.onTapGesture`/`.contextMenu` wrap what precedes
                // them and take the touch first. Hoisting a FULL-BLEED panel then ate the deck's
                // horizontal pan, since `Text` and `Image` are hit-testable. Inset + real buttons is
                // the shape that satisfies both.
                .overlay(alignment: .bottom) { feedbackPanel(for: card) }

            VStack(spacing: 4) {
                Text(card.name).font(.title3.bold()).multilineTextAlignment(.center)
                PriceLabel(value: try? store.price(cardId: card.id)?.rawUsd)
                if let why = caption(card) {
                    Text(why).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal)

            // Real buttons, not gestures: the deck's taps are already spoken for (single tap is
            // left to the pan, double tap is Want), and these are the only VoiceOver-reachable
            // way off this card. `CardID` resolves on whichever stack pushed the deck — Discover
            // registers the destination for both entry points (See all, and Browse's All Cards).
            HStack(spacing: 12) {
                NavigationLink(value: CardID(raw: card.id)) {
                    Label("Card details", systemImage: "info.circle")
                }
                // Not a `ShareLink` — see `ShareSheet`. Every one of them tested on a real iPad
                // failed to present; this one sits in a card body rather than a toolbar, but
                // there is no reason left to believe that saves it.
                Button {
                    sharing = SharePayload(url: CardShareLink.url(card: card,
                                                                  setName: setName(of: card)))
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Share card")
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func feedbackPanel(for card: CardRecord) -> some View {
        if let panel, panel.cardId == card.id {
            switch panel {
            case .priority:
                if let wants {
                    CardFeedbackPanel(title: "Priority",
                                      options: WantPriority.panelOrder,
                                      label: { $0.panelLabel },
                                      systemImage: { $0.panelImage },
                                      effect: { _ in nil },
                                      selected: wants.entries[card.id]?.priority ?? .normal,
                                      onPick: { priority in
                                          wants.update(card.id) { $0.priority = priority }
                                          panelMotion { self.panel = nil }
                                      },
                                      onDismiss: { panelMotion { self.panel = nil } })
                }
            case .reason:
                CardFeedbackPanel(title: "Why?",
                                  options: DismissReason.allCases,
                                  label: { $0.shortLabel },
                                  systemImage: { $0.systemImage },
                                  effect: { $0.effect },
                                  selected: nil,
                                  onPick: { reason in
                                      signals?.dismiss(card.id, reason: reason)
                                      dismissCard(card.id)
                                  },
                                  // Closing without answering still stands: the card was hidden the
                                  // moment you tapped, and naming a reason is the optional part.
                                  onDismiss: { dismissCard(card.id) })
            }
        }
    }

    /// Every show/hide of the feedback panel, Reduce Motion aware.
    ///
    /// ⚠️ The five panel transitions each spelled out `withAnimation(.snappy)` and **none** of them
    /// read `reduceMotion`, while the heart's `symbolEffect` ten lines below did — so one screen
    /// honoured the setting for a 200 ms bounce and ignored it for a whole panel sliding in. One
    /// funnel rather than five guards, so a sixth transition can't be added without one.
    private func panelMotion(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.snappy, change) }
    }

    /// Take the rejected card out of the deck once the panel is done with it.
    ///
    /// ⚠️ Deferred to panel close rather than done on the tap, because the panel is attached to that
    /// card's page — removing the card immediately would destroy the panel before it could be read
    /// or answered.
    private func dismissCard(_ cardId: String) {
        panelMotion {
            panel = nil
            pager?.remove(cardId)
        }
    }

    /// Thumbs-down. Like the heart, the act is immediate — the card is hidden the moment you tap —
    /// and naming a reason afterwards is optional.
    @ViewBuilder
    private func thumbsDown(for card: CardRecord) -> some View {
        if let signals {
            Button {
                signals.dismiss(card.id)
                panelMotion { panel = .reason(cardId: card.id) }
            } label: {
                Image(systemName: "hand.thumbsdown")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.thinMaterial, in: Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(12)
            .accessibilityLabel("Not for me")
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
                let wasWanted = wants.isWanted(card.id)
                wants.toggle(card.id)
                wantBump += 1
                // The action already happened. The panel is the OPTIONAL refinement — ignore it and
                // the card stays on the wishlist at Normal. Removing a card offers nothing.
                panelMotion { panel = wasWanted ? nil : .priority(cardId: card.id) }
            } label: {
                Image(systemName: wants.isWanted(card.id) ? "heart.fill" : "heart")
                    .font(.title2)
                    // Pink, not red: DESIGN.md keys system pink to wishlist and red to losses,
                    // and this heart was the one place the two got swapped.
                    .foregroundStyle(wants.isWanted(card.id) ? Color.pink : Color.secondary)
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
