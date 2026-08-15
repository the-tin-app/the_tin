import SwiftUI

/// The transient "that isn't a Tin label" banner over a live QR viewfinder, plus the five-second
/// self-dismiss that goes with it.
///
/// Both label-scanner entry points show this: the Tin's ⋯ menu (`CollectionView`) and the Scan
/// tab's `Scanner | Binder | Label` picker (`ScanTabContainer`). It lived in both files as an
/// eleven-line copy — identical down to the padding — with the auto-dismiss `.task(id:)` copied
/// beside it. A fix to one silently missed the other, which is how a chrome shadow ended up in
/// two places at once.
///
/// ⚠️ No `.shadow()`. `.thinMaterial` already separates the capsule from the camera feed, and the
/// Flat Tin Rule reserves shadows for card art. The material is doing the work the shadow was
/// added for; over a moving preview the shadow read as a web card.
///
/// The auto-dismiss is keyed on the message rather than on a bool so a SECOND bad scan restarts
/// the five seconds instead of inheriting the first one's remaining time — `.task(id:)` cancels
/// and re-runs when the id changes, and two consecutive scans of the same packing slip produce
/// the same string, which correctly leaves the countdown alone.
extension View {
    func scanErrorBanner(_ message: Binding<String?>) -> some View {
        overlay {
            if let text = message.wrappedValue {
                Text(text)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 22)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .task(id: message.wrappedValue) {
            guard message.wrappedValue != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation { message.wrappedValue = nil }
        }
    }
}
