import Foundation
import Network
import Observation

/// Drives the offline banner (spec §6). Backed by NWPathMonitor; updates hop to the
/// main actor since `isOffline` is read from SwiftUI.
@Observable
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    var isOffline = false
    /// True on cellular / personal hotspot — a link the user may be paying for by the byte.
    /// The scanner pack is several hundred MB, so its download auto-pauses when this flips on
    /// (`ScannerPackModel`).
    ///
    /// `isExpensive` OR an explicit cellular interface check, not `isExpensive` alone: on device,
    /// dropping Wi-Fi for cellular did not flip `isExpensive` on its own, so the auto-pause never
    /// fired. `usesInterfaceType(.cellular)` is the unambiguous signal; `isExpensive` stays in
    /// because it additionally covers a personal hotspot and carrier-flagged Wi-Fi.
    var isExpensive = false
    /// Human-readable path, surfaced in Settings — without it, "why didn't it pause?" is
    /// unanswerable from the device.
    var connectionDescription = "…"

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            let cellular = path.usesInterfaceType(.cellular)
            let expensive = path.isExpensive || cellular
            let description = offline ? "Offline"
                : cellular ? "Cellular"
                : path.usesInterfaceType(.wifi) ? (path.isExpensive ? "Wi-Fi (metered)" : "Wi-Fi")
                : path.usesInterfaceType(.wiredEthernet) ? "Wired"
                : expensive ? "Metered" : "Connected"
            Task { @MainActor in
                self?.isOffline = offline
                self?.isExpensive = expensive
                self?.connectionDescription = description
            }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor"))
    }

    deinit { monitor.cancel() }
}
