import Foundation

/// The three cumulative catalog tiers the self-hosted server publishes. Raw values match the
/// server manifest keys and `AppConfig.catalogTier` — wire format, never shown. Display copy
/// deliberately avoids rank/persona words ("Casual/Expert" read as account tiers, i.e. paywall
/// grammar; see PRODUCT.md's first anti-reference): user-facing this is a catalog *download
/// size* choice, and every size is free.
enum CatalogTier: String, CaseIterable, Identifiable {
    case casual, average, expert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .casual: return "Small"
        case .average: return "Standard"
        case .expert: return "Complete"
        }
    }

    /// What data the download includes + how often the app checks for updates.
    var summary: String {
        switch self {
        case .casual: return "Latest prices only. Smallest download, checks weekly."
        case .average: return "Latest prices plus a weekly price-history sparkline. Checks daily."
        case .expert: return "Everything — adds graded & per-condition price history. Checks daily."
        }
    }
}
