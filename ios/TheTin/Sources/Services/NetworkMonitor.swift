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
    /// (`ScannerPackModel`). Deliberately `isExpensive` rather than an interface-type check:
    /// it also covers a tethered Mac and carrier-flagged Wi-Fi.
    var isExpensive = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isOffline = path.status != .satisfied
                self?.isExpensive = path.isExpensive
            }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor"))
    }

    deinit { monitor.cancel() }
}
