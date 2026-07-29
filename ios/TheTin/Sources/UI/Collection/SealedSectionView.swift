import SwiftUI

/// The Sealed section of the tin: one row per sealed product you own, under a heading carrying the
/// section's own count and value.
///
/// A section rather than a divider tray. Dividers are for filing cards, and a booster box is not a
/// card you can file — mixing it into a riffle row would have meant either a card-shaped tile with
/// no card in it, or a divider whose count meant two different things.
///
/// The caller renders these directly into the tin's `List` (not wrapped in a container view), so
/// each row keeps its own swipe actions — `.swipeActions` only works on a direct child of a List.
struct SealedSectionHeader: View {
    let value: (total: Double, priced: Int, boxes: Int)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sealed")
                    .font(.system(.caption, design: .serif).italic().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value.total, format: .currency(code: "USD").precision(.fractionLength(0)))
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .monospacedDigit()
            }
            // Coverage stated whenever it's partial, for the same reason the card total states
            // it: a number that silently covers less than it appears to is worse than a gap.
            Text(value.priced == value.boxes
                 ? "^[\(value.boxes) box](inflect: true)"
                 : "^[\(value.boxes) box](inflect: true) · \(value.priced) priced")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One owned sealed product: photo, name, quantity, and what it's worth today.
struct SealedRow: View {
    let entry: SealedEntry
    /// nil when this catalog doesn't carry the product — an older artifact, or a product that has
    /// left the feed. The row still renders: you still own the box.
    let product: SealedProduct?

    private var value: Double? {
        product?.marketUsd.map { $0 * Double(entry.qty) }
    }

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: product?.imageURL)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(product?.name ?? "Sealed product \(entry.productId)")
                    .font(.subheadline).lineLimit(2)
                if entry.qty > 1 {
                    Text("×\(entry.qty)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            // "—", never $0: a box this catalog can't price is unknown, not worthless.
            Text(value.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(0))) } ?? "—")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
