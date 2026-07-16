import Foundation

enum HPFilter: Equatable {
    case exact(Int)
    case range(min: Int?, max: Int?)

    func matches(_ hp: Int?) -> Bool {
        guard let hp else { return false }
        switch self {
        case .exact(let v): return hp == v
        case .range(let min, let max):
            if let min, hp < min { return false }
            if let max, hp > max { return false }
            return true
        }
    }
}

/// A card's printed number, e.g. "58/112" → local "58", total 112 (the set's printed count).
struct CardNumberFilter: Equatable {
    let local: String
    let total: Int?
}

struct SearchQuery: Equatable {
    var nameTokens: [String] = []
    var hp: HPFilter? = nil
    var textPhrase: String? = nil
    var number: CardNumberFilter? = nil

    var isEmpty: Bool { nameTokens.isEmpty && hp == nil && textPhrase == nil && number == nil }

    static func parse(_ raw: String) -> SearchQuery {
        var query = SearchQuery()
        var rest = raw

        if let match = rest.range(of: "\"[^\"]+\"", options: .regularExpression) {
            let phrase = rest[match].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .trimmingCharacters(in: .whitespaces)
            if !phrase.isEmpty { query.textPhrase = phrase }
            rest.removeSubrange(match)
        }
        rest = rest.replacingOccurrences(of: "\"", with: " ")

        for token in rest.split(whereSeparator: \.isWhitespace) {
            let t = String(token)
            if t.lowercased().hasPrefix("hp:"), let filter = Self.parseHP(String(t.dropFirst(3))) {
                query.hp = filter
            } else if let number = Self.parseNumber(t) {
                query.number = number
            } else {
                query.nameTokens.append(t)
            }
        }
        return query
    }

    /// "58/112" (numerator/denominator, the printed convention) or "#58" (numerator only).
    /// Bare digits ("58") are left as a name token — too ambiguous with HP or card names.
    /// `local` keeps the typed digits verbatim (no Int round-trip) so zero-padded numbers
    /// ("008") still match `card.number` exactly.
    private static func parseNumber(_ value: String) -> CardNumberFilter? {
        if value.hasPrefix("#") {
            let digits = value.dropFirst()
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            return CardNumberFilter(local: String(digits), total: nil)
        }
        guard let slash = value.firstIndex(of: "/") else { return nil }
        let localStr = value[..<slash]
        let totalStr = value[value.index(after: slash)...]
        guard !localStr.isEmpty, localStr.allSatisfy(\.isNumber), let total = Int(totalStr) else { return nil }
        return CardNumberFilter(local: String(localStr), total: total)
    }

    private static func parseHP(_ value: String) -> HPFilter? {
        // Check for a range separator first: Int("-200") would otherwise parse as
        // the exact value -200 instead of the range "min nil, max 200".
        if let dash = value.firstIndex(of: "-") {
            let loStr = value[..<dash]
            let hiStr = value[value.index(after: dash)...]
            let loEmpty = loStr.isEmpty
            let hiEmpty = hiStr.isEmpty
            let lo = loEmpty ? nil : Int(loStr)
            let hi = hiEmpty ? nil : Int(hiStr)
            guard (lo != nil || loEmpty), (hi != nil || hiEmpty), lo != nil || hi != nil else { return nil }
            return .range(min: lo, max: hi)
        }
        if let exact = Int(value) { return .exact(exact) }
        return nil
    }
}
