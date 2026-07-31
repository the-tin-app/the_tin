import Foundation

/// Priority of a wishlist card. Raw values are ordered so ascending sort = High first.
enum WantPriority: Int, Codable, CaseIterable, Identifiable {
    case high = 0, normal = 1, low = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        }
    }
}

/// One wishlist entry's per-card data. Every field defaults, so a plain `WantEntry()` is the
/// "just hearted it" state and legacy id-only wishlists migrate to it losslessly.
struct WantEntry: Codable, Hashable {
    var priority: WantPriority = .normal
    var targetUsd: Double? = nil
    var notes: String = ""
    var addedAt: Date = Date()
}
