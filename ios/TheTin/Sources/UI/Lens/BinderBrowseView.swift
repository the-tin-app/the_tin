import SwiftUI

/// The finished binder: a grid you flip through in real slot order, and a list you sort and filter.
///
/// The grid is **synthetic catalog art at the binder's real dimensions**, not the photograph (Tomas,
/// 2026-08-07). You are standing at a counter looking at the physical object; the app's job is to
/// label it, not to show you a worse picture of it.
struct BinderBrowseView: View {
    let model: BinderModel
    let store: CatalogStore
    @State private var showingList = false
    @State private var openSlot: BinderSlot?

    var body: some View {
        VStack(spacing: 0) {
            header
            // Both halves stay in the hierarchy — swapping them with a `switch` would re-identify the
            // whole subtree and lose the page you were on.
            ZStack {
                pages.opacity(showingList ? 0 : 1).allowsHitTesting(!showingList)
                BinderListView(model: model) { openSlot = $0 }
                    .opacity(showingList ? 1 : 0).allowsHitTesting(showingList)
            }
        }
        .sheet(item: $openSlot) { slot in
            NavigationStack {
                BinderSlotSheet(model: model, store: store, slot: slot)
            }
        }
    }

    private var header: some View {
        HStack {
            Picker("View", selection: $showingList) {
                Text("Binder").tag(false)
                Text("List").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            Spacer()
            Menu {
                Button("Scan another binder", systemImage: "camera") { model.reset() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Binder options")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var pages: some View {
        VStack(spacing: 0) {
            TabView {
                ForEach(Array(0..<model.pageCount), id: \.self) { page in
                    BinderPageGrid(model: model, page: page) { openSlot = $0 }
                        .padding(.horizontal, 10)
                }
            }
            .tabViewStyle(.page)
            summary
        }
    }

    /// One honest line. `unresolvedCount` is stated rather than hidden — an unlabelled pocket the user
    /// can see and tap is a task; an unlabelled pocket nobody mentions is the app looking broken.
    private var summary: some View {
        VStack(spacing: 3) {
            // ⚠️ TWO lines, and which line something lands on is the whole simplification. This used to
            // be one row of up to six chips — spinner, wishlist hits, cards found, need a choice, to
            // confirm, unread — which wrapped on a phone and read as a wall. The state you are IN goes
            // on top; the tallies that only matter once it has settled go underneath, muted.
            //
            // While pass B runs, the top line is the measured backlog rather than "Still reading…". On
            // an A10 that wait is minutes, and an unquantified spinner over a half-filled binder is
            // indistinguishable from a hang.
            HStack(spacing: 5) {
                if model.isWorking {
                    ProgressView().controlSize(.mini)
                    Text(model.readingStatus ?? "Still reading…").monospacedDigit()
                } else {
                    Text("^[\(model.resolvedCount) card](inflect: true) found")
                    if model.wishlistHitCount > 0 {
                        Label("^[\(model.wishlistHitCount) wishlist hit](inflect: true)",
                              systemImage: "heart.fill")
                            .foregroundStyle(.pink)
                    }
                }
            }
            .font(.caption)

            // The tallies. Still stated rather than hidden — an unlabelled pocket the user can see and
            // tap is a task, one nobody mentions is the app looking broken — just no longer competing
            // with the headline for the same row.
            HStack(spacing: 6) {
                if model.isWorking {
                    Text("^[\(model.resolvedCount) card](inflect: true) so far")
                }
                if model.unresolvedCount > 0 { Text("\(model.unresolvedCount) need a choice") }
                if model.unconfirmedWishlistCount > 0 {
                    Text("\(model.unconfirmedWishlistCount) to confirm").foregroundStyle(.pink)
                }
                if model.unreadCount > 0 { Text("\(model.unreadCount) unread") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            // ⚠️ Not optional politeness. A photograph cannot tell one printing of a card from
            // another, so a bare price beside it claims a precision the app does not have.
            Text("Prices are a guide — a photo can't tell which printing a card is.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

/// One page of pockets, at the binder's real dimensions and in real slot order.
private struct BinderPageGrid: View {
    let model: BinderModel
    let page: Int
    let onTap: (BinderSlot) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(0..<model.shape.rows), id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(Array(0..<model.shape.cols), id: \.self) { col in
                        let slot = BinderSlot(page: page, row: row, col: col)
                        let entry = model.entry(slot)
                        Button { onTap(slot) } label: {
                            Pocket(entry: entry,
                                   card: entry?.displayCardId.flatMap { model.cardCache[$0] },
                                   price: entry?.displayCardId.flatMap { model.priceCache[$0] },
                                   isWorking: model.isWorking)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("Page \(page + 1) of \(model.pageCount)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

/// A single pocket. Three states, and none of them is a failure: a card, a card we can't name yet, or
/// an empty pocket.
private struct Pocket: View {
    let entry: BinderSlotEntry?
    /// Carried in, never looked up: a grid of pockets re-renders constantly and a catalog read in
    /// this `body` would run per pocket per render.
    let card: CardRecord?
    let price: Double?
    /// ⚠️ Pass B is the slow stage, and a pocket gets its entry as soon as DETECT runs — so between the
    /// two it is unresolved with no options and no reason, which is byte-identical to "couldn't be read".
    /// Without this the grid tells the user a page of readable cards is unreadable, for several seconds,
    /// before quietly correcting itself.
    let isWorking: Bool

    private var isStillReading: Bool {
        isWorking && entry != nil && entry?.displayCardId == nil
            && entry?.options.isEmpty == true && entry?.unreadable == nil
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(.secondarySystemBackground))
                if let entry, entry.displayCardId != nil {
                    CardImageView(card: card, quality: "low")
                        // ⚠️ An unconfirmed pass-A candidate must not look like a settled answer. Dimmed
                        // with a "?" over it: the guess is worth showing — it is a match against ~120
                        // wanted cards — but it is a guess, and looking identical to a lock is precisely
                        // the confident wrong answer this rendering exists to stop.
                        .opacity(entry.isResolved ? 1 : 0.45)
                        .overlay {
                            if !entry.isResolved {
                                Image(systemName: "questionmark.circle.fill")
                                    .font(.title3).foregroundStyle(.white, .black.opacity(0.55))
                            }
                        }
                } else if isStillReading {
                    ProgressView().controlSize(.small)
                } else if let entry {
                    // A pocket the app couldn't read is NOT the same picture as one it can offer a
                    // choice for, and it must not be the same picture as an empty pocket either.
                    Image(systemName: entry.unreadable != nil ? "eye.slash" : "questionmark")
                        .font(.title3).foregroundStyle(.secondary)
                }
            }
            .aspectRatio(0.72, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(entry?.onWishlist == true ? Color.pink : Color.clear, lineWidth: 2.5))
            .overlay(alignment: .topTrailing) {
                if entry?.onWishlist == true {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 9)).foregroundStyle(.white)
                        .padding(3).background(Circle().fill(.pink))
                        .padding(2)
                        .accessibilityHidden(true)
                }
            }

            if let entry, !entry.isResolved, entry.wishlistCandidate != nil {
                Text("probably — tap").font(.system(size: 9)).foregroundStyle(.pink)
            } else if let price {
                Text(price, format: .currency(code: "USD"))
                    .font(.system(size: 9)).monospacedDigit().lineLimit(1)
            } else if entry == nil {
                Text("empty").font(.system(size: 9)).foregroundStyle(.secondary)
            } else if isStillReading {
                Text("reading…").font(.system(size: 9)).foregroundStyle(.secondary)
            } else if entry?.options.isEmpty == false {
                Text("tap to pick").font(.system(size: 9)).foregroundStyle(.secondary)
            } else if let why = entry?.unreadable {
                // Verbatim, so "reflection" and "blur" tell the user what to change about the shot.
                Text(why).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            } else if !(entry?.isResolved ?? false) {
                // ⚠️ NOT "tap to pick". A pocket the gate could not read has no candidates to pick
                // from, and measured over 90 real cells its four best guesses held the true card
                // **1 time in 12** — so offering them would be wrong eleven times out of twelve.
                // The old label promised a list and opened a sheet with nothing in it.
                Text("not read").font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Text(" ").font(.system(size: 9))     // keeps rows the same height
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        guard let entry else { return "Empty pocket" }
        if isStillReading { return "Still reading" }
        if !entry.isResolved, entry.wishlistCandidate != nil {
            return "Probably \(card?.name ?? "a card you want") — tap to confirm"
        }
        guard entry.isResolved else {
            if let why = entry.unreadable { return "Couldn't be read — \(why)" }
            return entry.options.isEmpty ? "Couldn't be read, tap to search" : "Needs a choice"
        }
        var parts = [card?.name ?? entry.cardId ?? "Card"]
        if entry.onWishlist { parts.append("on your wishlist") }
        if let price { parts.append(price.formatted(.currency(code: "USD"))) }
        return parts.joined(separator: ", ")
    }
}

/// One pocket, opened: the catalog's art beside **your actual crop of the photograph**.
///
/// ⚠️ The crop is the point of this screen. Synthetic art makes a wrong identification invisible —
/// nothing on the grid disagrees with a confident wrong answer, however wrong it is. Putting the
/// photograph next to the catalog picture is what turns "trust it" into "check it", and it is what
/// gives a correction an evidence base instead of a guess.
struct BinderSlotSheet: View {
    let model: BinderModel
    let store: CatalogStore
    let slot: BinderSlot
    @State private var searching = false
    /// Resolved ONCE in `.task`, never in `body`. ⚠️ `store.card(id:)` and `store.set(id:)` are
    /// synchronous GRDB reads, and `body` re-runs — building four options inline meant eight catalog
    /// reads per render of this sheet. Same class of mistake as the twelve synchronous reads that used
    /// to sit in `CardDetailModel.init`, which cost a 10 s main-thread hang on an A10.
    @State private var chooserOptions: [ChooserOption] = []
    @Environment(\.dismiss) private var dismiss

    private var entry: BinderSlotEntry? { model.entry(slot) }

    var body: some View {
        List {
            Section {
                comparison
            } header: {
                Text("Page \(slot.page + 1) · row \(slot.row + 1), column \(slot.col + 1)")
            }

            if let entry, entry.isResolved, let cardId = entry.cardId {
                Section {
                    LabeledContent("Card", value: model.name(cardId))
                    if let set = model.setNameCache[cardId] {
                        LabeledContent("Set", value: set)
                    }
                    if let price = model.priceCache[cardId] {
                        LabeledContent("Price") {
                            Text(price, format: .currency(code: "USD")).monospacedDigit()
                        }
                    }
                    if entry.onWishlist {
                        Label("On your wishlist", systemImage: "heart.fill").foregroundStyle(.pink)
                    }
                }
            }

            // The chooser, if the gate withheld a lock. Same 2×2 sheet the live scanner uses, and it
            // held the true card 48 times out of 48 over the measured binder cells.
            if !chooserOptions.isEmpty {
                Section("Which one is it?") {
                    CardChooser(options: chooserOptions,
                                escape: "None of these — search instead",
                                onPick: { model.pick($0, for: slot); dismiss() },
                                onEscape: { searching = true })
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            // Says why, rather than leaving a blank sheet. 5 of the 12 unread cells in the measured
            // set had an EMPTY OCR pool — the card's name and number didn't read — so "we couldn't
            // read it" is the honest description, not "we don't know this card".
            if let entry, !entry.isResolved, entry.options.isEmpty {
                Section {
                    Text(entry.unreadable.map {
                        "This card couldn't be read — \($0). Re-shoot the page, or search for it."
                    } ?? "The name and number on this card didn't read, so there is nothing to choose between. Search for it, or re-shoot the page a little closer.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Pick a different card", systemImage: "magnifyingglass") { searching = true }
                if entry != nil {
                    Button("Nothing in this pocket", systemImage: "xmark", role: .destructive) {
                        model.clearSlot(slot); dismiss()
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
        }
        .task(id: entry?.options ?? []) {
            let ids = entry?.options ?? []
            guard !ids.isEmpty else { chooserOptions = []; return }
            let store = self.store
            chooserOptions = await Task.detached(priority: .userInitiated) {
                ids.map { BinderSlotSheet.option(id: $0, store: store) }
            }.value
        }
        .sheet(isPresented: $searching) {
            NavigationStack {
                // Reused, not rebuilt: a card search that already handles prices, wishlist marks and
                // a debounced query is not worth writing twice.
                TradeCatalogPicker(store: store, title: "Which card is it?") { card in
                    model.pick(card.id, for: slot)
                    searching = false
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder private var comparison: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                Text("Your photo").font(.caption2).foregroundStyle(.secondary)
                TileCrop(url: model.tileURL(entry?.tile ?? ""),
                         crop: entry?.crop ?? .zero)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(0.72, contentMode: .fit)
            }
            VStack(spacing: 4) {
                Text("The catalog").font(.caption2).foregroundStyle(.secondary)
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground))
                    if let card = entry?.cardId.flatMap({ model.cardCache[$0] }) {
                        // The set name comes from the batch the model already read — never a lookup
                        // here. Offline this pane IS the fact sheet, and "Darkness Ablaze #136" is
                        // what you check against the card in your hand; "SWSH3" is not.
                        CardImageView(card: card, quality: "high",
                                      setName: entry?.cardId.flatMap { model.setNameCache[$0] })
                    } else {
                        Image(systemName: "questionmark").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(0.72, contentMode: .fit)
            }
        }
        .padding(.vertical, 4)
    }

    /// Three states, three different questions — and the third one must not pretend to be the second.
    private var title: String {
        guard let entry else { return "Empty pocket" }
        if entry.isResolved { return "Check it" }
        return entry.options.isEmpty ? "Couldn't read it" : "Which card?"
    }

    /// `nonisolated static` so it can run inside `Task.detached` — the same shape as
    /// `CardDetailModel.load()`'s reader.
    nonisolated static func option(id: String, store: CatalogStore) -> ChooserOption {
        let card = try? store.card(id: id)
        let set = card.flatMap { try? store.set(id: $0.setId) }
        return ChooserOption(id: id, card: card, setName: set?.name,
                             year: set?.releaseDate.map { String($0.prefix(4)) },
                             setTotal: set?.total)
    }
}

/// The stored tile JPEG, cropped to one pocket. Decoded off the MainActor and once — a `List` row's
/// `body` re-runs, and re-decoding an image inside it is how this app has previously eaten memory.
private struct TileCrop: View {
    let url: URL
    let crop: CGRect
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground))
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                // Honest: the tile JPEG is written on a background task after the shot, and the cache
                // may have been evicted — neither is an error worth a red banner.
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .task(id: url.path + "\(crop)") { await load() }
    }

    private func load() async {
        let url = self.url, crop = self.crop
        image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            let w = CGFloat(full.width), h = CGFloat(full.height)
            // A little margin around the pocket: the quad hugs the card, and seeing a sliver of the
            // pocket around it is what makes the crop legible as a photograph rather than a swatch.
            let box = CGRect(x: crop.minX * w, y: crop.minY * h,
                             width: crop.width * w, height: crop.height * h)
                .insetBy(dx: -crop.width * w * 0.06, dy: -crop.height * h * 0.06)
                .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard !box.isEmpty else { return full }
            return full.cropping(to: box) ?? full
        }.value
    }
}

/// The grid's sibling: every card the scan found, sortable and filterable, each row carrying its slot
/// so the list points back at the physical binder.
struct BinderListView: View {
    @Bindable var model: BinderModel
    let onTap: (BinderSlot) -> Void

    var body: some View {
        List {
            if model.rows.isEmpty {
                ContentUnavailableView("Nothing here yet",
                                       systemImage: "rectangle.grid.3x2",
                                       description: Text(model.resolvedCount > 0
                                                         ? "No card matches these filters."
                                                         : "Photograph a page to fill the binder."))
            } else {
                ForEach(model.rows) { row in
                    Button { onTap(row.slot) } label: { BinderRowView(row: row) }
                        .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top) { controls }
    }

    private var controls: some View {
        HStack {
            Picker("Sort", selection: $model.filter.sort) {
                ForEach(BinderSort.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            Spacer()
            Menu {
                Toggle("Only my wishlist", isOn: $model.filter.wishlistOnly)
                Toggle("Hide what I own", isOn: $model.filter.hideOwned)
                // Fixed steps, not a number field: a decimal-pad TextField in a List has no return
                // key and no way to dismiss the keyboard, and "roughly how cheap" is the only
                // question anyone asks standing at a counter.
                Picker("Price", selection: $model.filter.maxPriceUsd) {
                    Text("Any price").tag(Double?.none)
                    Text("$5 and under").tag(Double?.some(5))
                    Text("$10 and under").tag(Double?.some(10))
                    Text("$25 and under").tag(Double?.some(25))
                }
                if !model.setNames.isEmpty {
                    Picker("Set", selection: $model.filter.setName) {
                        Text("Every set").tag(String?.none)
                        ForEach(model.setNames, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Filter")
        }
        .padding(.horizontal).padding(.vertical, 6)
        .background(.bar)
    }
}

/// ⚠️ Reads everything off `row`. It must NEVER query the catalog: a synchronous GRDB read inside a
/// `List` row's `body` is re-run on every render of every visible row.
/// ⚠️ Never name a variant here either — a photo cannot tell a reverse holo from a regular one, so no
/// printing-specific claim (price included) may be made.
private struct BinderRowView: View {
    let row: BinderRow

    var body: some View {
        HStack(spacing: 10) {
            CardImageView(card: row.card, quality: "low").frame(width: 34)
                .opacity(row.confirmed ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1)
                Text(row.setName.map { "\(row.position) · \($0)" } ?? row.position)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !row.confirmed {
                    // Says "probably" out loud. This row is pass A's guess, and the whole reason it is a
                    // guess is that pass A has no separation, OCR or twin check behind it.
                    Text(row.onWishlist ? "Probably on your wishlist — tap to confirm"
                                        : "Not confirmed — tap to confirm")
                        .font(.caption2).foregroundStyle(.pink)
                } else if row.onWishlist {
                    Text("On your wishlist").font(.caption2).foregroundStyle(.pink)
                } else if row.owned {
                    Text("Already in your tin").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let price = row.priceUsd {
                Text(price, format: .currency(code: "USD")).monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }
}
