import SwiftUI
import UIKit

/// The system share sheet, presented as a SHEET instead of through `ShareLink`.
///
/// ## Why this exists
///
/// `ShareLink` in the list toolbars does not present usably on iPad. On the For Trade and Wanted
/// screens it drew a small, permanently uninteractable card at the centre of the screen — the
/// share popover anchored to the wrong view — while the identical control on `CardDetailView`
/// worked on the same device. Four structural differences were tested on an iPad Pro 11 simulator
/// on 2026-08-01 and **all four were ruled out**: nesting inside a `Menu`, the absence of an
/// explicit `SharePreview`, the ~1,800-character payload URL, and wrapping the `ShareLink` in an
/// `if let` inside its `ToolbarItem`. Every one of them still failed.
///
/// So the presentation is no longer SwiftUI's to get right. A `UIActivityViewController` inside a
/// `.sheet` needs **no popover anchor at all** — iPad renders it as a form sheet, iPhone as the
/// usual sheet — which removes the entire class of failure rather than another guess at it.
///
/// iPhone was never affected: there the share sheet is full-height and never uses the anchor,
/// which is exactly why this shipped in v1.0 and went unnoticed until an iPad tried to use it.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A URL to share, as a `.sheet(item:)` payload. `URL` is `Identifiable` only from iOS 16 in some
/// SDKs and its `id` would be the whole string anyway, so this names the intent instead.
struct SharePayload: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
