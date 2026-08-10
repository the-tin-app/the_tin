import SwiftUI

/// What a label print run needs. Identifiable so flipping it presents the picker, exactly like
/// `PrintSheetRequest` — the entry points stay one-liners.
struct LabelPrintRequest: Identifiable {
    let title: String
    let entries: [CollectionEntry]
    let id = UUID()
}

/// Which label position to start printing at, shown as the sheet itself — 4 × 10 tappable slots,
/// the used ones greyed. A sheet with twelve labels peeled off is otherwise unusable, and at 40 up
/// that is most of a sheet's worth of stock thrown away each time.
struct LabelStartPositionPicker: View {
    let stock: LabelStock
    let labelCount: Int
    @Binding var startPosition: Int
    let onPrint: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: stock.columns)
    }

    /// How many of this sheet's slots the run will actually use — the honest count, after the
    /// blanks the start position leaves behind.
    private var sheetsNeeded: Int {
        let firstSheet = stock.perSheet - (startPosition - 1)
        guard labelCount > firstSheet else { return 1 }
        return 1 + Int(ceil(Double(labelCount - firstSheet) / Double(stock.perSheet)))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Tap the first unused label").font(.headline)
            Text("Positions before it are left blank, so a part-used sheet isn't wasted.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(1...stock.perSheet, id: \.self) { position in
                    Button {
                        startPosition = position
                    } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(position < startPosition ? Color.secondary.opacity(0.25)
                                                           : Color.accentColor.opacity(0.18))
                            .aspectRatio(2, contentMode: .fit)
                            .overlay {
                                if position == startPosition {
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Start at label \(position)")
                }
            }
            .padding(.horizontal)
            Text("\(labelCount) label\(labelCount == 1 ? "" : "s") · \(sheetsNeeded) sheet\(sheetsNeeded == 1 ? "" : "s")")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Print") {
                dismiss()
                onPrint()
            }
            .buttonStyle(.borderedProminent)
            Button("Cancel", role: .cancel) { dismiss() }
        }
        .padding()
    }
}

extension View {
    /// Attach once per screen; set the binding to print that divider's labels. Mirrors
    /// `printSheetFlow`: picker → cancellable render overlay → share sheet.
    func labelPrintFlow(_ request: Binding<LabelPrintRequest?>, store: CatalogStore) -> some View {
        modifier(LabelPrintFlow(request: request, store: store))
    }

    /// The calibration page on its own — no entries, no picker, straight to a PDF.
    func labelCalibrationFlow(isActive: Binding<Bool>) -> some View {
        modifier(LabelCalibrationFlow(isActive: isActive))
    }
}

private struct LabelPrintFlow: ViewModifier {
    @Binding var request: LabelPrintRequest?
    let store: CatalogStore
    @State private var startPosition = 1
    @State private var rendering = false
    @State private var renderTask: Task<Void, Never>?
    @State private var share: SharePDF?

    func body(content: Content) -> some View {
        content
            .sheet(item: $request) { req in
                LabelStartPositionPicker(
                    stock: .spartanR005,
                    // Counted, not built: the whole tin is thousands of entries and building a
                    // LabelItem (with its URL) per physical card just to call `.count` would do
                    // that work on the main thread as the sheet animates in.
                    labelCount: req.entries.reduce(0) { $0 + ($1.isSold ? 0 : max($1.qty, 1)) },
                    startPosition: $startPosition,
                    onPrint: { start(req) })
                    .presentationDetents([.medium, .large])
            }
            .overlay {
                if rendering {
                    VStack(spacing: 12) {
                        ProgressView("Preparing labels…")
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

    private func start(_ req: LabelPrintRequest) {
        cancelRender()   // a second tap must not race the prior render/share
        rendering = true
        let entries = req.entries
        let start = startPosition
        let store = store
        renderTask = Task { @MainActor in
            // Catalog reads are synchronous and off-MainActor-safe; a whole tin is thousands of
            // rows, so they don't belong on the thread drawing the overlay.
            let (cards, setNames) = await Task.detached(priority: .userInitiated) {
                let cards = Dictionary(uniqueKeysWithValues:
                    ((try? store.cards(ids: entries.map(\.cardId))) ?? []).map { ($0.id, $0) })
                let setNames = Dictionary(uniqueKeysWithValues:
                    ((try? store.sets()) ?? []).map { ($0.id, $0.name) })
                return (cards, setNames)
            }.value
            guard !Task.isCancelled else { return }

            let offset = LabelSheet.savedOffset()
            let items = LabelSheet.items(entries: entries, cards: cards, setNames: setNames)
            let pages = LabelSheet.pages(items: items, stock: .spartanR005,
                                         startPosition: start, offset: offset)
            let data = await SheetPDF.render(pages: pages.map {
                LabelSheetPage(page: $0, stock: .spartanR005, offset: offset)
            })
            guard !Task.isCancelled else { return }
            rendering = false
            guard !data.isEmpty else { return }   // CGContext failure path: stop, don't present
            let name = req.title.replacingOccurrences(of: "/", with: "-") + " labels.pdf"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            share = SharePDF(url: url)
        }
    }
}

private struct LabelCalibrationFlow: ViewModifier {
    @Binding var isActive: Bool
    @State private var share: SharePDF?

    func body(content: Content) -> some View {
        content
            .task(id: isActive) {
                guard isActive else { return }
                let offset = LabelSheet.savedOffset()
                let data = await SheetPDF.render(pages: [
                    LabelCalibrationPage(stock: .spartanR005, offset: offset)
                ])
                defer { isActive = false }   // LAST: flipping it re-keys this very task
                guard !data.isEmpty else { return }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Label alignment.pdf")
                guard (try? data.write(to: url, options: .atomic)) != nil else { return }
                share = SharePDF(url: url)
            }
            .sheet(item: $share) { ActivityShareSheet(items: [$0.url]) }
    }
}
