import SwiftUI
import UIKit

/// The system share sheet, presented as a SHEET instead of through `ShareLink`.
///
/// ## Why this exists
///
/// **`ShareLink` does not present usably on iPad in this app — anywhere. Do not reintroduce one.**
///
/// On the For Trade and Wanted screens it drew a small, permanently uninteractable card at the
/// centre of the screen; on card detail it collapsed to an ellipsis bubble that never opened.
/// Four structural differences were tested on an iPad Pro 11 simulator on 2026-08-01 and **all
/// four were ruled out**: nesting inside a `Menu`, the absence of an explicit `SharePreview`, the
/// ~1,800-character payload URL, and wrapping the `ShareLink` in an `if let` inside its
/// `ToolbarItem`. Every one still failed. So the presentation stopped being SwiftUI's to get
/// right: a `UIActivityViewController` inside a `.sheet` needs **no popover anchor at all** —
/// iPad renders a form sheet, iPhone the usual sheet.
///
/// ⚠️ **This doc comment used to say `CardDetailView`'s `ShareLink` "worked on the same device",
/// and that was wrong.** It worked on an iPad Pro 11 **simulator running iOS 26**; on the real
/// iPad (A10, iOS 18.7.9) it fails like all the others. On the strength of that false contrast it
/// was left as a `ShareLink` and shipped broken for another day. The lesson is not about sharing:
/// **an iPad bug must be reproduced on the iPad's OS version**, and the newest available runtime
/// is not a substitute. `grep ShareLink(` should return nothing but this comment.
///
/// iPhone is genuinely unaffected — there the sheet is full-height and never uses an anchor —
/// which is why this shipped in v1.0 and went unnoticed until an iPad tried to use it.
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
