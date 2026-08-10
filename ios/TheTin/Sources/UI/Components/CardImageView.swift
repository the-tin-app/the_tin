import SwiftUI
import UIKit

/// Card art loaded through the durable `ImageCache` (offline after first view); NULL image_base
/// or a load failure falls back to a placeholder with set/number text (spec §6, contract §3.3).
/// `card` is optional so callers with no representative card (e.g. a set with a null `repCardId`)
/// can render a generic placeholder tile without a crash.
struct CardImageView: View {
    let card: CardRecord?
    let quality: String // "low" for grids, "high" for detail
    /// Handed to `CardFactSheet` so the no-art fallback can print "Darkness Ablaze #136/189"
    /// instead of "SWSH3 #136". Optional and defaulted: callers that do not already hold the set
    /// pass nothing, and NOBODY looks one up for this — see the note on `CardFactSheet.setName`.
    var setName: String?
    var setTotal: Int?
    @State private var image: Image?
    /// Downloading right now, as opposed to "there is no art" or "the fetch failed".
    ///
    /// The placeholder used to render identically in all three states, so a slow queue was
    /// indistinguishable from a broken one — reported 2026-07-27 as "no way to see if a card is
    /// actively downloading, stuck, etc.", after a too-tight download cap made every grid look
    /// like it was missing its assets.
    @State private var isLoading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Decoded images, kept in memory so a tile scrolling back into view is free.
    ///
    /// `ImageCache` is a DISK cache: it hands back `Data`. Every appearance re-read the file and
    /// re-ran `UIImage(data:)`, because `.task(id:)` fires on every appearance and `load` began by
    /// clearing `image`. Scrolling a grid therefore decoded dozens of images per second, forever —
    /// the art being already downloaded made no difference, which is exactly how this was found
    /// (2026-07-27: "even with the images already downloaded, it is still painful to scroll" on an
    /// iPad 7th gen). The download cap had nothing to do with it.
    ///
    /// `NSCache` rather than a dictionary: it is thread-safe and evicts itself under memory
    /// pressure, so a long browse can't grow unbounded and can't get us jetsammed.
    ///
    /// Limited by BYTES, not count. This started at `countLimit = 300`, which counts images while
    /// the thing that actually matters is bitmaps: decoded grid art runs ~335 KB apiece, so 300 of
    /// them is ~100 MB held on a device with 3 GB total. A jetsam kill is also the one crash class
    /// Crashlytics can never report (SIGKILL is uncatchable), so it would have been invisible.
    /// The ceiling is a fraction of physical memory; NSCache still evicts under pressure below it.
    private static let decoded: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = min(256 << 20, Int(ProcessInfo.processInfo.physicalMemory / 32))
        return cache
    }()

    var body: some View {
        Group {
            if let card {
                loaded(card)
                    .task(id: card.imageURL(quality: quality)) { await load(card) }
            } else {
                placeholder(for: nil)
            }
        }
        .aspectRatio(0.717, contentMode: .fit) // standard card ratio
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func loaded(_ card: CardRecord) -> some View {
        if let image {
            image.resizable().aspectRatio(contentMode: .fit)
                .transition(.opacity) // cross-fades in over the placeholder instead of popping
        } else if isLoading {
            // A spinner while the bytes are on their way; the informative placeholder (set/number,
            // or the printed facts at detail size) is what you get once we know there's nothing
            // coming. Two different messages — "wait" and "this is all there is" — that used to
            // look the same.
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .overlay { ProgressView().controlSize(.small) }
                .accessibilityLabel("Loading image for \(card.name)")
        } else {
            placeholder(for: card)
        }
    }

    private func load(_ card: CardRecord) async {
        // No art for this card at all: never a loading state, so the placeholder shows immediately
        // rather than spinning at something that will never arrive.
        guard let url = card.imageURL(quality: quality) else { image = nil; return }

        // Already decoded: show it synchronously. Deliberately BEFORE clearing `image` and without
        // an animation — a recycled tile used to blank to its placeholder and cross-fade back in
        // every time it scrolled past, which is the "jumpy" half of the same complaint.
        if let hit = Self.decoded.object(forKey: url as NSURL) {
            image = Image(uiImage: hit)
            return
        }

        image = nil
        isLoading = true
        defer { isLoading = false }
        guard let data = await ImageCache.shared.image(for: url) else { return }
        let decodedImage = await Task.detached(priority: .utility) { UIImage(data: data) }.value
        guard let decodedImage else { return }
        // Cache BEFORE the cancellation check, deliberately. Fast scrolling cancels a tile's task
        // the moment it leaves the screen, and this guard used to sit ahead of the write — so a
        // decode that had already finished was thrown away, then paid for again on the way back
        // up. That is exactly the "I scroll back up, images seem to need to re-load" report
        // (2026-07-27). Cancellation should skip the UI update, never discard completed work.
        Self.decoded.setObject(decodedImage, forKey: url as NSURL,
                               cost: decodedImage.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        guard !Task.isCancelled else { return }
        if reduceMotion {
            image = Image(uiImage: decodedImage)
        } else {
            withAnimation(.easeOut(duration: 0.25)) { image = Image(uiImage: decodedImage) }
        }
    }

    /// No art: render the card from catalog data instead of a grey box.
    ///
    /// ⚠️ Both qualities get a real sheet now. The grid used to fall back to `SVI` / `#223` and
    /// nothing else, which is the screen you stand in front of a binder with — 36 pockets of grey
    /// boxes at a convention, "no better off than you were 5 seconds ago". The name was already in
    /// memory the whole time; this was a rendering choice, never missing data.
    private func placeholder(for card: CardRecord?) -> some View {
        Group {
            if let card {
                CardFactSheet(card: card, density: quality == "high" ? .full : .compact,
                              setName: setName, setTotal: setTotal)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            }
        }
    }
}
