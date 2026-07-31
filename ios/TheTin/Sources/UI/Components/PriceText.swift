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
    /// Show nothing instead of "no data" when there's no value.
    ///
    /// "no data" means *the catalog can't price this* — an honest and useful thing to say about a
    /// card you own. It's the wrong thing to say about a card you've sold, where there is no
    /// current value to report by definition. Absent ≠ missing.
    var hidesNoData: Bool = false

    var body: some View {
        if let value {
            Text(value, format: .currency(code: "USD")).font(.caption.bold()).monospacedDigit()
        } else if !hidesNoData {
            Text("no data").font(.caption).foregroundStyle(.secondary)
        }
    }
}
