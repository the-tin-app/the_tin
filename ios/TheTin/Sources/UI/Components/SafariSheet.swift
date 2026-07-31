import SwiftUI
import SafariServices

/// In-app browser sheet (SFSafariViewController) so marketplace links keep users in the app.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
