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
                ForEach(0..<model.pageCount, id: \.self) { page in
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
            HStack(spacing: 10) {
                if model.wishlistHitCount > 0 {
                    Label("^[\(model.wishlistHitCount) wishlist hit](inflect: true)",
                          systemImage: "heart.fill")
                        .foregroundStyle(.pink)
                }
                Text("^[\(model.resolvedCount) card](inflect: true) found")
                if model.unresolvedCount > 0 {
                    Text("· \(model.unresolvedCount) need a choice")
                }
            }
            .font(.caption)
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
            ForEach(0..<model.shape.rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<model.shape.cols, id: \.self) { col in
                        let slot = BinderSlot(page: page, row: row, col: col)
                        let entry = model.entry(slot)
                        Button { onTap(slot) } label: {
                            Pocket(entry: entry,
                                   card: entry?.cardId.flatMap { model.cardCache[$0] },
                                   price: entry?.cardId.flatMap { model.priceCache[$0] })
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

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(.secondarySystemBackground))
                if let entry, entry.isResolved {
                    CardImageView(card: card, quality: "low")
                } else if entry != nil {
                    Image(systemName: "questionmark").font(.title3).foregroundStyle(.secondary)
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

            if let price {
                Text(price, format: .currency(code: "USD"))
                    .font(.system(size: 9)).monospacedDigit().lineLimit(1)
            } else if entry == nil {
                Text("empty").font(.system(size: 9)).foregroundStyle(.secondary)
            } else if entry?.options.isEmpty == false {
                Text("tap to pick").font(.system(size: 9)).foregroundStyle(.secondary)
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
        guard entry.isResolved else {
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
            if let options = entry?.options, !options.isEmpty {
                Section("Which one is it?") {
                    CardChooser(options: options.map(chooserOption),
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
                    Text("The name and number on this card didn't read, so there is nothing to choose between. Search for it, or re-shoot the page a little closer.")
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
                TileCrop(url: BinderCache.shared.tileURL(entry?.tile ?? ""),
                         crop: entry?.crop ?? .zero)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(0.72, contentMode: .fit)
            }
            VStack(spacing: 4) {
                Text("The catalog").font(.caption2).foregroundStyle(.secondary)
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground))
                    if let card = entry?.cardId.flatMap({ model.cardCache[$0] }) {
                        CardImageView(card: card, quality: "high")
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

    private func chooserOption(_ id: String) -> ChooserOption {
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
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1)
                Text(row.setName.map { "\(row.position) · \($0)" } ?? row.position)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if row.onWishlist {
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
