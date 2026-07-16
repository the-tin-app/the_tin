import SwiftUI
import UIKit

/// Generic multi-page PDF rendering shared by the trade/want print sheets and the insurance
/// report. One SheetPage per paper page; render() draws
/// each SwiftUI page into a CGContext PDF via ImageRenderer, so text stays vector-crisp at
/// print size. US Letter only — A4 is handled by the print dialog's scale-to-fit.
enum SheetPDF {
    static let letter = CGSize(width: 612, height: 792)   // US Letter portrait, points
    static let margin: CGFloat = 36                        // 0.5 in
    /// UserDefaults key for the Settings "Printout contact line" field (empty = omit).
    static let contactLineKey = "printoutContactLine"

    /// Draw each page view into one PDF. MainActor because ImageRenderer is MainActor-bound.
    /// Checks Task.isCancelled between pages so long renders (insurance report) can abort; the
    /// yield gives the run loop a chance to actually deliver a pending Cancel tap between pages.
    @MainActor
    static func render(pages: [some View], pageSize: CGSize = letter) async -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
        for page in pages {
            if Task.isCancelled { break }
            let renderer = ImageRenderer(content: page)
            renderer.proposedSize = ProposedViewSize(pageSize)
            renderer.render { _, draw in
                pdf.beginPDFPage(nil)
                draw(pdf)
                pdf.endPDFPage()
            }
            await Task.yield()
        }
        pdf.closePDF()
        return data as Data
    }
}

/// The shared page frame: header (title / generation date / optional contact), body, footer
/// ("Page N of M · Prices as of <asOf> · The Tin"). Fixed light appearance — paper is white.
struct SheetPage<Content: View>: View {
    let title: String
    let subtitle: String?
    let contact: String?
    let pageNumber: Int
    let pageCount: Int
    let asOf: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(SheetPDF.margin)
        .frame(width: SheetPDF.letter.width, height: SheetPDF.letter.height)
        .background(.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 16, weight: .bold))
                Spacer()
                if let subtitle {
                    Text(subtitle).font(.system(size: 9)).foregroundStyle(.black.opacity(0.6))
                }
            }
            if let contact, !contact.isEmpty {
                Text(contact).font(.system(size: 9)).foregroundStyle(.black.opacity(0.6))
            }
            Rectangle().fill(.black).frame(height: 0.8).padding(.top, 6)
        }
        .padding(.bottom, 10)
    }

    private var footer: some View {
        Text(footerText)
            .font(.system(size: 8)).foregroundStyle(.black.opacity(0.55))
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }

    private var footerText: String {
        var parts = ["Page \(pageNumber) of \(pageCount)"]
        if let asOf { parts.append("Prices as of \(asOf)") }
        parts.append("The Tin")
        return parts.joined(separator: " · ")
    }
}

extension Array {
    /// [items] → [[≤size items]] print pages; the last chunk holds the remainder.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}

extension SheetPDF {
    /// Warm + collect card art through the durable ImageCache, ≤4 downloads at a time.
    /// Missing/offline images are simply absent from the result — page bodies draw bordered
    /// placeholders, so a sheet still renders fully offline. `progress(done, total)` fires
    /// after each batch (the insurance report drives its progress bar with it).
    static func fetchImages(for cards: [(id: String, card: CardRecord)], quality: String,
                            progress: (@MainActor (Int, Int) -> Void)? = nil) async -> [String: UIImage] {
        var images: [String: UIImage] = [:]
        var done = 0
        // ponytail: batch-of-4 gating (a slow straggler stalls its batch of 4); switch to a
        // sliding-window TaskGroup if 1000-image prefetches feel lumpy in practice.
        for batch in cards.chunked(into: 4) {
            if Task.isCancelled { break }
            await withTaskGroup(of: (String, UIImage?).self) { group in
                for (id, card) in batch {
                    group.addTask {
                        guard let url = card.imageURL(quality: quality),
                              let data = await ImageCache.shared.image(for: url),
                              let raw = UIImage(data: data)
                        else { return (id, nil) }
                        // ponytail: images downscaled to ~2× draw size; bounds memory and PDF
                        // size for large dividers
                        return (id, downscaled(raw))
                    }
                }
                for await (id, image) in group where image != nil { images[id] = image }
            }
            done += batch.count
            if let progress { await progress(done, cards.count) }
        }
        return images
    }

    /// Cap an image to ~300×420pt (≈2× the 151pt-tall print draw size), preserving aspect
    /// ratio. Never upscales. Internal (not private) so it's covered by a unit test.
    static func downscaled(_ image: UIImage, maxSize: CGSize = CGSize(width: 300, height: 420)) -> UIImage {
        let size = image.size
        let scale = min(maxSize.width / size.width, maxSize.height / size.height, 1)
        guard scale < 1 else { return image }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// Identifiable wrapper so a rendered PDF's URL can drive `.sheet(item:)`.
struct SharePDF: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Share sheet — AirPrint, Save to Files, AirDrop all come free. No custom print UI.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
