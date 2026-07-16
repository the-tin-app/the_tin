import Foundation

/// The three cumulative catalog tiers the self-hosted server publishes. Raw values match the
/// server manifest keys and `AppConfig.catalogTier`. Carries the Settings picker's display copy so
/// "what each tier includes" lives in one place. See the 3-tier packaging spec.
enum CatalogTier: String, CaseIterable, Identifiable {
    case casual, average, expert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .casual: return "Casual"
        case .average: return "Average"
        case .expert: return "Expert"
        }
    }

    /// What data the tier includes + how often the app checks for updates.
    var summary: String {
        switch self {
        case .casual: return "Latest prices only. Smallest download, checks weekly."
        case .average: return "Latest prices plus a weekly price-history sparkline. Checks daily."
        case .expert: return "Everything — adds graded & per-condition price history. Checks daily."
        }
    }
}
