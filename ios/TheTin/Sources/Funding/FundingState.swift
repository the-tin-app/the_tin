import Foundation

/// Community-funding health state mirrored from the backend into the catalog manifest.
/// Ordering (best → worst): green > yellow > red > black. `unknown` is used whenever the
/// backend value is missing or unrecognized, and decoding NEVER throws because of it.
enum FundingState: Equatable {
    case green
    case yellow
    case red
    case black
    case unknown
}

extension FundingState: Codable {
    /// Shared string→state mapping. Any nil/unrecognized value maps to `.unknown`; this is the
    /// single source of truth so callers (e.g. `FundingSnapshot`'s custom decode) never
    /// duplicate the switch.
    static func from(raw: String?) -> FundingState {
        switch raw ?? "" {
        case "GREEN": return .green
        case "YELLOW": return .yellow
        case "RED": return .red
        case "BLACK": return .black
        default: return .unknown
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try? container.decode(String.self)
        self = FundingState.from(raw: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let raw: String
        switch self {
        case .green: raw = "GREEN"
        case .yellow: raw = "YELLOW"
        case .red: raw = "RED"
        case .black: raw = "BLACK"
        case .unknown: raw = "UNKNOWN"
        }
        try container.encode(raw)
    }
}
