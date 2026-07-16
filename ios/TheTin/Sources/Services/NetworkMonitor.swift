import Foundation
import Network
import Observation

/// Drives the offline banner (spec §6). Backed by NWPathMonitor; updates hop to the
/// main actor since `isOffline` is read from SwiftUI.
@Observable
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    var isOffline = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOffline = path.status != .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor"))
    }

    deinit { monitor.cancel() }
}
