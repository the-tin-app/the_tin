import SwiftUI
import UIKit

/// Assembles the insurance report's pages for the shared SheetPDF renderer: cover page,
/// value-sorted inventory table pages, and the per-divider subtotal appendix. Page bodies are
/// AnyView-wrapped so one homogeneous [SheetPage<AnyView>] can mix the three body kinds.
///
/// Layout follows approved mockup B ("zebra table + centered cover"): the cover is centered (not
/// left-aligned) and table rows alternate background shading instead of rule dividers.
enum ReportPages {
    static let rowsPerPage = 14        // spec: ~12–15 rows/page
    static let subtotalsPerPage = 20

    /// Two entries per exhibit page.
    ///
    /// ⚠️ This was THREE on paper and three does not fit. The arithmetic said a block is
    /// 176 pt of photo + ~28 pt of caption ≈ 204 pt, so three would land at ~640 pt inside a
    /// ~700 pt body. Rendered, three worst-case blocks measure **727 pt** — the caption wraps to
    /// two lines at realistic name/set lengths and the per-photo labels cost more than the
    /// estimate. `ReportPhotoLayoutTests` measures it rather than trusting the sum; if a caption
    /// ever grows again, that test fails and this constant is the knob to turn.
    static let photosPerPage = 2

    /// Entries with at least one photo on file. An empty `EntryPhotos` is NOT an exhibit.
    static func photoRows(_ rows: [ReportRow]) -> [ReportRow] {
        rows.filter { !($0.photos?.isEmpty ?? true) }
    }

    /// Which page each photographed entry's exhibit lands on, so the inventory row can print
    /// "Photo p.N". Pure arithmetic, extracted from `build` so the marker is testable without
    /// rendering a PDF. Page 1 is the cover; exhibits follow the inventory and sealed sections.
    static func photoPageIndex(rowPages: Int, sealedPages: Int,
                               photoRows: [ReportRow]) -> [String: Int] {
        var index: [String: Int] = [:]
        for (i, chunk) in photoRows.chunked(into: photosPerPage).enumerated() {
            let page = 2 + rowPages + sealedPages + i
            for row in chunk { index[row.id] = page }
        }
        return index
    }

    @MainActor
    static func build(rows: [ReportRow], totals: ReportTotals, subtotals: [DividerSubtotal],
                      images: [String: UIImage], asOf: String?, contact: String?,
                      sealed: [SealedReportRow] = [],
                      photoImages: [String: [(label: String, image: UIImage)]] = [:])
                      -> [SheetPage<AnyView>] {
        let generated = Date.now.formatted(date: .long, time: .omitted)
        let rowChunks = rows.chunked(into: rowsPerPage)
        // Sealed pages sit between the cards and the divider appendix — after the cards, because
        // that is the inventory the document is mostly about, and before the appendix, because the
        // appendix closes the report with the grand totals.
        let sealedChunks = sealed.isEmpty ? [] : sealed.chunked(into: sealedRowsPerPage)
        // Only entries whose photos actually loaded get an exhibit — a file that failed to read
        // must not produce a marker pointing at a blank page.
        let exhibits = photoRows(rows).filter { photoImages[$0.id]?.isEmpty == false }
        let photoChunks = exhibits.chunked(into: photosPerPage)
        let photoPages = photoPageIndex(rowPages: rowChunks.count,
                                        sealedPages: sealedChunks.count, photoRows: exhibits)
        let subChunks = subtotals.isEmpty ? [[]] : subtotals.chunked(into: subtotalsPerPage)
        let total = 1 + rowChunks.count + sealedChunks.count + photoChunks.count + subChunks.count

        func page(_ n: Int, _ body: @escaping () -> AnyView) -> SheetPage<AnyView> {
            SheetPage(title: "Collection Report", subtitle: generated, contact: contact,
                      pageNumber: n, pageCount: total, asOf: asOf, content: body)
        }

        var pages = [page(1) {
            AnyView(ReportCoverBody(totals: totals, asOf: asOf, sealed: sealed,
                                    photographed: exhibits.count))
        }]
        for (i, chunk) in rowChunks.enumerated() {
            pages.append(page(2 + i) {
                AnyView(ReportTableBody(rows: chunk, images: images, photoPages: photoPages))
            })
        }
        for (i, chunk) in sealedChunks.enumerated() {
            pages.append(page(2 + rowChunks.count + i) {
                AnyView(ReportSealedBody(rows: chunk,
                                         total: sealed.compactMap(\.currentValue).reduce(0, +),
                                         boxes: sealed.reduce(0) { $0 + $1.qty },
                                         showTotals: i == sealedChunks.count - 1))
            })
        }
        let photoOffset = 2 + rowChunks.count + sealedChunks.count
        for (i, chunk) in photoChunks.enumerated() {
            pages.append(page(photoOffset + i) {
                AnyView(ReportPhotoBody(rows: chunk, images: photoImages, showsHeading: i == 0))
            })
        }
        for (i, chunk) in subChunks.enumerated() {
            pages.append(page(photoOffset + photoChunks.count + i) {
                AnyView(ReportAppendixBody(subtotals: chunk, totals: totals,
                                           showTotals: i == subChunks.count - 1))
            })
        }
        return pages
    }

    /// Sealed rows are text-only (no thumbnail column), so more fit on a page than card rows.
    static let sealedRowsPerPage = 22
}

/// The sealed inventory: one table section after the cards, with its own subtotal.
///
/// Its own section rather than extra rows in the card table, for the same reason sealed is its own
/// section in the tin: the card table's CARD/DETAIL/QTY columns describe a printing, a condition
/// and a grade, none of which a shrink-wrapped box has.
struct ReportSealedBody: View {
    let rows: [SealedReportRow]
    let total: Double
    let boxes: Int
    let showTotals: Bool      // true only on the final sealed page

    private static let zebra = Color(white: 0.949)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sealed products").font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 8)
            headerRow
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                tableRow(row).background(index.isMultiple(of: 2) ? Self.zebra : Color.clear)
            }
            if showTotals {
                HStack(spacing: 6) {
                    Text("Sealed total").font(.system(size: 11, weight: .bold))
                    Spacer()
                    Text("\(boxes) box\(boxes == 1 ? "" : "es")").font(.system(size: 11))
                        .frame(width: 70, alignment: .trailing)
                    Text(total.formatted(.currency(code: "USD")))
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.vertical, 5)
                // Sealed products carry a market price and no price history, so they are valued
                // but never charted. Stated here because an insurance document must not leave the
                // reader to infer which numbers cover what.
                Text("Sealed products are valued at market price; they have no price history.")
                    .font(.system(size: 9)).foregroundStyle(.black.opacity(0.6))
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("PRODUCT").font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.black.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
            head("QTY", width: 22, alignment: .trailing)
            head("ACQUIRED", width: 56)
            head("FROM", width: 70)
            head("PAID", width: 54, alignment: .trailing)
            head("VALUE", width: 58, alignment: .trailing)
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(.black).frame(height: 0.8) }
    }

    private func head(_ s: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(s).font(.system(size: 7, weight: .semibold))
            .foregroundStyle(.black.opacity(0.6))
            .frame(width: width, alignment: alignment)
    }

    private func tableRow(_ row: SealedReportRow) -> some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                if !row.productType.isEmpty {
                    Text(row.productType).font(.system(size: 8))
                        .foregroundStyle(.black.opacity(0.6)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            cell("\(row.qty)", width: 22, alignment: .trailing)
            cell(row.acquiredAt.map { $0.formatted(date: .numeric, time: .omitted) } ?? "", width: 56)
            cell(row.acquiredFrom ?? "", width: 70)
            cell(row.pricePaid.map { $0.formatted(.currency(code: "USD")) } ?? "",
                 width: 54, alignment: .trailing)
            // "—", never $0 — the same rule the card table follows for an unpriced row.
            Text(row.currentValue.map { $0.formatted(.currency(code: "USD")) } ?? "—")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private func cell(_ s: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(s).font(.system(size: 8)).lineLimit(2)
            .frame(width: width, alignment: alignment)
    }
}

/// Cover: big total, coverage note, cost basis, method note, app version. Centered per mockup B
/// (vs. mockup A's left-aligned layout).
struct ReportCoverBody: View {
    let totals: ReportTotals
    let asOf: String?
    var sealed: [SealedReportRow] = []
    /// ⚠️ Counts ENTRIES, while "Valued: X of Y cards" counts Σ qty. The label says so.
    var photographed: Int = 0

    private var sealedValue: Double { sealed.compactMap(\.currentValue).reduce(0, +) }
    private var sealedBoxes: Int { sealed.reduce(0) { $0 + $1.qty } }
    private var sealedBasis: Double { sealed.compactMap(\.pricePaid).reduce(0, +) }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            // Cards AND sealed. This number is what the document is FOR — an insurance report that
            // silently omits the sealed half would understate the claim it exists to support. The
            // breakdown below keeps the two legible, and the per-divider appendix still means
            // cards, because dividers hold cards.
            Text((totals.totalValue + sealedValue).formatted(.currency(code: "USD")))
                .font(.system(size: 44, weight: .bold))
                .padding(.top, 100)   // mockup B: .total{margin-top:120px} vs A's 60px
            if let asOf {
                Text("Prices as of \(asOf)")
                    .font(.system(size: 11)).foregroundStyle(.black.opacity(0.6))
                    .padding(.top, 4)
            }
            VStack(alignment: .center, spacing: 6) {
                Text("\(totals.totalCards) cards · \(totals.totalEntries) entries")
                // Coverage note — an insurance document must not silently pretend coverage.
                Text("Valued: \(totals.pricedCards) of \(totals.totalCards) cards")
                if photographed > 0 {
                    Text("Photographed: \(photographed) of \(totals.totalEntries) entries")
                }
                if sealedBoxes > 0 {
                    Text("Cards \(totals.totalValue.formatted(.currency(code: "USD"))) · Sealed \(sealedValue.formatted(.currency(code: "USD"))) across \(sealedBoxes) box\(sealedBoxes == 1 ? "" : "es")")
                }
                Text("Cost basis: \((totals.costBasis + sealedBasis).formatted(.currency(code: "USD")))")
            }
            .font(.system(size: 12))
            .multilineTextAlignment(.center)
            .padding(.top, 18)
            Spacer()
            Text("Values are TCGplayer-derived market prices, condition- and grade-aware where recorded.")
                .font(.system(size: 9)).foregroundStyle(.black.opacity(0.6))
                .multilineTextAlignment(.center)
            Text("Generated by The Tin \(appVersion)")
                .font(.system(size: 9)).foregroundStyle(.black.opacity(0.6))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// One inventory table page (≤ rowsPerPage rows). Missing provenance = blank cells; missing
/// price = "—"; missing image = bordered placeholder (report generates fully offline).
/// Rows use zebra striping (mockup B) instead of per-row rule dividers (mockup A).
struct ReportTableBody: View {
    let rows: [ReportRow]            // ≤ ReportPages.rowsPerPage
    let images: [String: UIImage]    // by ReportRow.id, low-quality tier
    /// Entry id → the exhibit page its photos print on. Empty when nothing is photographed.
    var photoPages: [String: Int] = [:]

    /// Matches mockup B's `tr:nth-child(even) td{background:#f2f2f2}` — the header is the odd
    /// "row" so the first data row (index 0) lands on an even table row and is shaded.
    private static let zebra = Color(white: 0.949)

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                tableRow(row)
                    .background(index.isMultiple(of: 2) ? Self.zebra : Color.clear)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            head("", width: 31)
            Text("CARD").font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.black.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
            head("DETAIL", width: 76)
            head("QTY", width: 22, alignment: .trailing)
            head("ACQUIRED", width: 56)
            head("FROM", width: 70)
            head("PAID", width: 54, alignment: .trailing)
            head("VALUE", width: 58, alignment: .trailing)
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(.black).frame(height: 0.8) }
    }

    private func head(_ s: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(s).font(.system(size: 7, weight: .semibold))
            .foregroundStyle(.black.opacity(0.6))
            .frame(width: width, alignment: alignment)
    }

    private func tableRow(_ row: ReportRow) -> some View {
        HStack(alignment: .center, spacing: 6) {
            thumb(row).frame(width: 31, height: 43)   // ~0.6 in
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                Text(row.setLine).font(.system(size: 8))
                    .foregroundStyle(.black.opacity(0.6)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.detail).font(.system(size: 8)).lineLimit(2)
                if let page = photoPages[row.id] {
                    Text("Photo p.\(page)").font(.system(size: 7))
                        .foregroundStyle(.black.opacity(0.6))
                }
            }
            .frame(width: 76, alignment: .leading)
            cell("\(row.qty)", width: 22, alignment: .trailing)
            cell(row.acquiredAt.map { $0.formatted(date: .numeric, time: .omitted) } ?? "",
                 width: 56)
            cell(row.acquiredFrom ?? "", width: 70)
            cell(row.pricePaid.map { $0.formatted(.currency(code: "USD")) } ?? "",
                 width: 54, alignment: .trailing)
            Text(row.currentValue.map { $0.formatted(.currency(code: "USD")) } ?? "—")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private func cell(_ s: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(s).font(.system(size: 8)).lineLimit(2)
            .frame(width: width, alignment: alignment)
    }

    @ViewBuilder private func thumb(_ row: ReportRow) -> some View {
        if let ui = images[row.id] {
            Image(uiImage: ui).resizable().aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 2).strokeBorder(.black.opacity(0.3), lineWidth: 0.5)
        }
    }
}

/// Appendix: per-divider subtotals; the last appendix page adds grand totals and
/// cost basis vs current value.
struct ReportAppendixBody: View {
    let subtotals: [DividerSubtotal]   // ≤ ReportPages.subtotalsPerPage
    let totals: ReportTotals
    let showTotals: Bool               // true only on the final appendix page

    private static let zebra = Color(white: 0.949)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Summary by divider").font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 8)
            ForEach(Array(subtotals.enumerated()), id: \.element.id) { index, sub in
                HStack(spacing: 6) {
                    Text(sub.name).font(.system(size: 10)).lineLimit(1)
                    Spacer()
                    Text("\(sub.cards) card\(sub.cards == 1 ? "" : "s")")
                        .font(.system(size: 10)).foregroundStyle(.black.opacity(0.6))
                        .frame(width: 70, alignment: .trailing)
                    Text(sub.value.formatted(.currency(code: "USD")))
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.vertical, 3)
                .background(index.isMultiple(of: 2) ? Self.zebra : Color.clear)
            }
            if showTotals {
                HStack(spacing: 6) {
                    Text("Total").font(.system(size: 11, weight: .bold))
                    Spacer()
                    Text("\(totals.totalCards) cards").font(.system(size: 11))
                        .frame(width: 70, alignment: .trailing)
                    Text(totals.totalValue.formatted(.currency(code: "USD")))
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.vertical, 5)
                Text("Cost basis \(totals.costBasis.formatted(.currency(code: "USD"))) · Current value \(totals.totalValue.formatted(.currency(code: "USD")))")
                    .font(.system(size: 9)).foregroundStyle(.black.opacity(0.6))
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

extension View {
    /// Attach once per screen; flip the binding to generate. Shows a determinate progress sheet
    /// while card art prefetches (the slow part — 1000+ entries is tens of pages), is cancellable
    /// by dismissing/Cancel, then hands the finished PDF to the share sheet.
    func collectionReportFlow(isActive: Binding<Bool>, collection: CollectionModel,
                              store: CatalogStore) -> some View {
        modifier(CollectionReportFlow(isActive: isActive, collection: collection, store: store))
    }
}

private struct CollectionReportFlow: ViewModifier {
    @Binding var isActive: Bool
    let collection: CollectionModel
    let store: CatalogStore
    @State private var progress = 0.0
    @State private var phase = "Fetching card images…"
    @State private var share: SharePDF?

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    VStack(spacing: 16) {
                        ProgressView(value: progress) { Text("Building collection report…") }
                        Text(phase).font(.footnote).foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel) { isActive = false }
                    }
                    .padding(24)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    // .task is cancelled when the overlay is removed (isActive flips false) —
                    // Cancel and the success path both abort the prefetch batches and the
                    // between-pages check in SheetPDF.render. Only one .sheet(item:) is ever
                    // presented at a time (matches PrintSheetFlow's overlay+share pattern).
                    .task { await generate() }
                }
            }
            .sheet(item: $share) { ActivityShareSheet(items: [$0.url]) }
    }

    @MainActor
    private func generate() async {
        progress = 0
        phase = "Fetching card images…"
        // CollectionModel is @MainActor — snapshot the plain-value state it holds before
        // hopping off Main for the (synchronous, potentially large) aggregation below.
        let entries = collection.entries
        let groups = collection.groups
        let prices = collection.prices
        let variantsByCard = collection.variantsByCard
        let conditionsByCard = collection.conditionsByCard
        let matrixByCard = collection.matrixByCard
        let gradedByPrintingByCard = collection.gradedByPrintingByCard
        let sealedRows = InsuranceReport.sealedRows(collection.sealed,
                                                    products: collection.sealedProducts)
        let store = store

        // DB reads (CatalogStore is not @MainActor) + InsuranceReport aggregation are
        // synchronous CPU/IO work — run detached so a big collection doesn't block the UI
        // thread before the progress overlay even finishes animating in.
        let (rows, totals, subs, asOf) = await Task.detached(priority: .userInitiated) {
            let cards = Dictionary(uniqueKeysWithValues:
                ((try? store.cards(ids: entries.map(\.cardId))) ?? []).map { ($0.id, $0) })
            let setNames = Dictionary(uniqueKeysWithValues:
                ((try? store.sets()) ?? []).map { ($0.id, $0.name) })
            let rows = InsuranceReport.rows(entries: entries, cards: cards, setNames: setNames,
                                            prices: prices, variantsByCard: variantsByCard,
                                            conditionsByCard: conditionsByCard,
                                            matrixByCard: matrixByCard,
                                            gradedByPrintingByCard: gradedByPrintingByCard)
            let totals = InsuranceReport.totals(entries: entries, prices: prices,
                                                variantsByCard: variantsByCard,
                                                conditionsByCard: conditionsByCard,
                                                matrixByCard: matrixByCard,
                                                gradedByPrintingByCard: gradedByPrintingByCard)
            let subs = InsuranceReport.subtotals(entries: entries, groups: groups, prices: prices,
                                                 variantsByCard: variantsByCard,
                                                 conditionsByCard: conditionsByCard,
                                                 matrixByCard: matrixByCard,
                                                 gradedByPrintingByCard: gradedByPrintingByCard)
            return (rows, totals, subs, (try? store.priceAsOf()) ?? nil)
        }.value
        guard !Task.isCancelled else { return }

        // Low tier: small at print size, keeps prefetch fast for big collections. Downloads and
        // decoding run off-main inside fetchImages/ImageCache.
        let images = await SheetPDF.fetchImages(
            for: rows.compactMap { row in row.card.map { (row.id, $0) } },
            quality: "low") { done, total in
            progress = Double(done) / Double(max(total, 1))
        }
        guard !Task.isCancelled else { return }

        // The user's own photos are local disk reads — fast, but off-main like every other read
        // in this flow. Labels come from EntryPhotos so a missing front doesn't relabel the back.
        let photoStore = PhotoStore.default()
        let photoImages = await Task.detached(priority: .userInitiated) {
            var out: [String: [(label: String, image: UIImage)]] = [:]
            for row in rows {
                guard let photos = row.photos, !photos.isEmpty else { continue }
                let shots = photos.labelled.compactMap { item in
                    photoStore.image(entryId: row.id, file: item.file)
                        .map { (label: item.label, image: $0) }
                }
                if !shots.isEmpty { out[row.id] = shots }
            }
            return out
        }.value
        guard !Task.isCancelled else { return }

        phase = "Rendering PDF…"
        let pages = ReportPages.build(rows: rows, totals: totals, subtotals: subs, images: images,
                                      asOf: asOf,
                                      contact: UserDefaults.standard.string(forKey: SheetPDF.contactLineKey),
                                      sealed: sealedRows, photoImages: photoImages)
        // ponytail: ImageRenderer is MainActor-bound, so page rasterization runs on main
        // (SheetPDF.render checks Task.isCancelled between pages). Everything slow —
        // aggregation and image fetch/decoding — already ran off-main above. Revisit only if
        // 100+ page reports visibly stutter.
        let data = await SheetPDF.render(pages: pages)
        guard !Task.isCancelled else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Collection Report.pdf")
        isActive = false
        guard (try? data.write(to: url)) != nil else { return }
        share = SharePDF(url: url)
    }
}

/// The photo exhibit: the collector's own photographs, three entries to a page.
///
/// Photos are `.scaledToFit()` inside the card-shaped box rather than filled: a phone photo is
/// 4:3, and cropping it to card aspect would cut off exactly the edges and corners a condition
/// claim is about.
struct ReportPhotoBody: View {
    let rows: [ReportRow]                                        // ≤ ReportPages.photosPerPage
    let images: [String: [(label: String, image: UIImage)]]      // by ReportRow.id, print order
    let showsHeading: Bool                                       // first exhibit page only

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeading {
                Text("Photographs").font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            ForEach(rows) { row in block(row) }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func block(_ row: ReportRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array((images[row.id] ?? []).enumerated()), id: \.offset) { _, shot in
                    VStack(spacing: 2) {
                        Image(uiImage: shot.image).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 126, height: 176)
                            .border(.black.opacity(0.15), width: 0.5)
                        Text(shot.label).font(.system(size: 7))
                            .foregroundStyle(.black.opacity(0.6))
                    }
                }
                Spacer(minLength: 0)
            }
            // The same fields the inventory row prints, so a row and its exhibit are
            // unambiguously the same line item.
            Text(caption(row)).font(.system(size: 9))
        }
    }

    private func caption(_ row: ReportRow) -> String {
        var parts = [row.name]
        if !row.setLine.isEmpty { parts.append(row.setLine) }
        if !row.detail.isEmpty { parts.append(row.detail) }
        parts.append(row.currentValue.map { $0.formatted(.currency(code: "USD")) } ?? "—")
        return parts.joined(separator: " · ")
    }
}
