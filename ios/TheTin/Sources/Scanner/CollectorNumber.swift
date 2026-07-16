import Foundation

struct ParsedNumber: Equatable { let number: String; let total: Int }

enum CollectorNumber {
    static func parse(_ raw: String) -> ParsedNumber? {
        // First "N/M" occurrence, tolerating spaces around the slash.
        guard let m = raw.range(of: #"(\d{1,4})\s*/\s*(\d{1,4})"#, options: .regularExpression) else { return nil }
        let frag = raw[m]
        let parts = frag.split(separator: "/")
        guard parts.count == 2,
              let total = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let numRaw = parts[0].trimmingCharacters(in: .whitespaces)
        let number = String(Int(numRaw) ?? 0)   // strip leading zeros; "25"
        return ParsedNumber(number: number, total: total)
    }
}
