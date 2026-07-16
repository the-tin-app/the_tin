import SwiftUI
import UIKit

/// One cell of a 6-up print sheet — everything the paper shows for a card.
struct PrintItem: Identifiable, Equatable {
    let id: String          // entry id (trade) / card id (want)
    let card: CardRecord
    let setName: String
    let chips: [String]     // trade: printing/condition/grade/×qty (only what's set); want: rarity
    let unitPrice: Double?  // nil prints "—"
    let qty: Int            // shown ×N beside the price so a vendor prices per card
}

enum PrintSheet {
    static let cardsPerPage = 6

    /// Divider entries → print items, entry-value descending (unpriced last). The printed price
    /// is the UNIT price — the same condition/grade/variant-aware number the app shows
    /// (GroupStats.entryValue with qty forced to 1).
    static func tradeItems(entries: [CollectionEntry], cards: [String: CardRecord],
                           setNames: [String: String], prices: [String: PriceRecord],
                           variantsByCard: [String: [VariantPrice]],
                           conditionsByCard: [String: [ConditionPrice]]) -> [PrintItem] {
        let sorted = GroupStats.sortedByValueDescending(entries: entries, prices: prices,
                                                        variantsByCard: variantsByCard,
                                                        conditionsByCard: conditionsByCard)
        return sorted.compactMap { entry in
            guard let card = cards[entry.cardId] else { return nil }
            var one = entry
            one.qty = 1
            let unit = GroupStats.entryValue(one, price: prices[entry.cardId],
                                             variants: variantsByCard[entry.cardId] ?? [],
                                             conditions: conditionsByCard[entry.cardId] ?? [])
            var chips = [entry.variantValue?.label, entry.condition, entry.gradeValue?.label]
                .compactMap { $0 }
            if entry.qty > 1 { chips.append("×\(entry.qty)") }
            return PrintItem(id: entry.id, card: card,
                             setName: setNames[card.setId] ?? card.setId,
                             chips: chips, unitPrice: unit, qty: entry.qty)
        }
    }

    /// Wishlist cards → print items. Wishlist stores bare card ids, so chips are rarity only and
    /// the price is the NM/raw market price. Value descending, unpriced last, name tie-break.
    static func wantItems(cards: [CardRecord], setNames: [String: String],
                          prices: [String: PriceRecord]) -> [PrintItem] {
        cards
            .map { card in
                PrintItem(id: card.id, card: card, setName: setNames[card.setId] ?? card.setId,
                          chips: [card.rarity].compactMap { $0 },
                          unitPrice: prices[card.id]?.rawUsd, qty: 1)
            }
            .sorted { ($0.unitPrice ?? -1, $1.card.name) > (($1.unitPrice ?? -1), $0.card.name) }
    }
}

/// One printed page body: 2 columns × 3 rows of cards (layout approved via HTML mockup).
struct SheetGridPage: View {
    let items: [PrintItem]           // ≤ PrintSheet.cardsPerPage
    let images: [String: UIImage]    // by PrintItem.id; missing → bordered placeholder

    var body: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 14) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { col in
                        if row * 2 + col < items.count {
                            let item = items[row * 2 + col]
                            SheetCell(item: item, image: images[item.id])
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One card cell: art (~2.1 in), name, "Set · #number", chip pills row, then a bold right-aligned
/// price row under a thin divider (mockup variant B). Unpriced prints "—". Missing art gets a
/// bordered named placeholder so the sheet still works at a card show with no signal.
struct SheetCell: View {
    let item: PrintItem
    let image: UIImage?

    var body: some View {
        VStack(spacing: 5) {
            art.frame(height: 151)   // 2.1 in
            VStack(alignment: .leading, spacing: 2) {
                Text(item.card.name)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(2).truncationMode(.tail)
                Text("\(item.setName) · #\(item.card.number)")
                    .font(.system(size: 9)).foregroundStyle(.black.opacity(0.6))
                    .lineLimit(2).truncationMode(.tail)
                if !item.chips.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(item.chips, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 8)).foregroundStyle(.black.opacity(0.6))
                                .lineLimit(1)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(.black.opacity(0.3), lineWidth: 0.5)
                                )
                        }
                    }
                }
                VStack(spacing: 2) {
                    Rectangle().fill(.black.opacity(0.15)).frame(height: 0.5)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Spacer(minLength: 0)
                        Text(item.unitPrice.map { $0.formatted(.currency(code: "USD")) } ?? "—")
                            .font(.system(size: 12, weight: .bold))
                        if item.qty > 1 {
                            Text("×\(item.qty)")
                                .font(.system(size: 9)).foregroundStyle(.black.opacity(0.6))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder private var art: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.black.opacity(0.35), lineWidth: 1)
                .aspectRatio(0.717, contentMode: .fit)
                .overlay {
                    Text(item.card.name)
                        .font(.system(size: 9)).foregroundStyle(.black.opacity(0.6))
                        .multilineTextAlignment(.center).padding(4)
                }
        }
    }
}

/// A tap on any "Print sheet…" entry point. Setting one on a printSheetFlow binding starts the
/// confirm (>20 pages) → prefetch → render → share flow.
struct PrintSheetRequest: Identifiable {
    let title: String        // "For Trade — <divider>" / "Want List"
    let items: [PrintItem]
    let asOf: String?
    let id = UUID()
    var pageCount: Int { items.chunked(into: PrintSheet.cardsPerPage).count }
}

extension PrintSheet {
    /// Everything a divider's trade sheet needs, gathered from the live model + catalog.
    @MainActor
    static func tradeRequest(group: CardGroup, model: CollectionModel,
                             store: CatalogStore) -> PrintSheetRequest {
        let entries = model.entries(in: group.id)
        let cards = Dictionary(uniqueKeysWithValues:
            ((try? store.cards(ids: entries.map(\.cardId))) ?? []).map { ($0.id, $0) })
        let setNames = Dictionary(uniqueKeysWithValues:
            ((try? store.sets()) ?? []).map { ($0.id, $0.name) })
        return PrintSheetRequest(
            title: "For Trade — \(group.name)",
            items: tradeItems(entries: entries, cards: cards, setNames: setNames,
                              prices: model.prices, variantsByCard: model.variantsByCard,
                              conditionsByCard: model.conditionsByCard),
            asOf: (try? store.priceAsOf()) ?? nil)
    }

    @MainActor
    static func wantRequest(cards: [CardRecord], store: CatalogStore) -> PrintSheetRequest {
        let setNames = Dictionary(uniqueKeysWithValues:
            ((try? store.sets()) ?? []).map { ($0.id, $0.name) })
        let prices = (try? store.prices(cardIds: cards.map(\.id))) ?? [:]
        return PrintSheetRequest(title: "Want List",
                                 items: wantItems(cards: cards, setNames: setNames, prices: prices),
                                 asOf: (try? store.priceAsOf()) ?? nil)
    }
}

extension View {
    /// Attach once per screen; set the binding to print. Handles the >20-page confirm dialog,
    /// image prefetch, PDF render, temp file, and the share sheet.
    func printSheetFlow(_ request: Binding<PrintSheetRequest?>) -> some View {
        modifier(PrintSheetFlow(request: request))
    }
}

private struct PrintSheetFlow: ViewModifier {
    @Binding var request: PrintSheetRequest?
    @State private var confirming: PrintSheetRequest?
    @State private var rendering = false
    @State private var share: SharePDF?
    @State private var renderTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id) { _, _ in
                guard let req = request else { return }
                request = nil
                // Huge divider (300+ cards → 50+ pages): confirm above 20 pages with the count.
                if req.pageCount > 20 { confirming = req } else { start(req) }
            }
            .confirmationDialog("Print \(confirming?.pageCount ?? 0) pages?",
                                isPresented: Binding(get: { confirming != nil },
                                                     set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible) {
                Button("Print \(confirming?.pageCount ?? 0) pages") {
                    if let req = confirming { confirming = nil; start(req) }
                }
                Button("Cancel", role: .cancel) { confirming = nil }
            } message: {
                Text("This sheet is longer than 20 pages.")
            }
            .overlay {
                if rendering {
                    VStack(spacing: 12) {
                        ProgressView("Preparing PDF…")
                        Button("Cancel", role: .cancel) { cancelRender() }
                    }
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .sheet(item: $share) { ActivityShareSheet(items: [$0.url]) }
    }

    private func cancelRender() {
        renderTask?.cancel()
        renderTask = nil
        rendering = false
    }

    private func start(_ req: PrintSheetRequest) {
        cancelRender()   // a second entry-point tap must not race the prior render/share
        rendering = true
        renderTask = Task { @MainActor in
            let images = await SheetPDF.fetchImages(for: req.items.map { ($0.id, $0.card) },
                                                    quality: "high")
            guard !Task.isCancelled else { return }
            let chunks = req.items.chunked(into: PrintSheet.cardsPerPage)
            let subtitle = Date.now.formatted(date: .abbreviated, time: .omitted)
            let contact = UserDefaults.standard.string(forKey: SheetPDF.contactLineKey)
            let pages = chunks.enumerated().map { i, chunk in
                SheetPage(title: req.title, subtitle: subtitle, contact: contact,
                          pageNumber: i + 1, pageCount: chunks.count, asOf: req.asOf) {
                    SheetGridPage(items: chunk, images: images)
                }
            }
            let data = await SheetPDF.render(pages: pages)
            guard !Task.isCancelled else { return }
            rendering = false
            guard !data.isEmpty else { return }   // CGContext failure path: stop, don't present
            let name = req.title.replacingOccurrences(of: "/", with: "-") + ".pdf"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            share = SharePDF(url: url)
        }
    }
}
