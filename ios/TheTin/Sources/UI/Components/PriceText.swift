import SwiftUI

/// Prices always carry their as-of date (user preference on record).
struct AsOfLabel: View {
    let date: String

    var body: some View {
        Text("as of \(date)")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

struct PriceLabel: View {
    let value: Double?

    var body: some View {
        if let value {
            Text(value, format: .currency(code: "USD")).font(.caption.bold()).monospacedDigit()
        } else {
            Text("no data").font(.caption).foregroundStyle(.secondary)
        }
    }
}
