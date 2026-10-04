import SwiftUI

/// Collecting mode (#198): "Some people are just here for the love of the game. Let me turn off the
/// card value views throughout the app so it can be just a collecting mode."
///
/// Scope, decided 2026-10-03: no values and no price changes anywhere you browse or file cards —
/// the tin and its dividers, card rows and grids, the card screen, the scan tray, Discover's price
/// shelves, the widget — and the Movers tab and Watching row go away, since they are nothing but
/// price movement. Tools you open *to* talk about money keep their numbers: a trade session and
/// the For Trade list, the wishlist (a target price means nothing without the market beside it),
/// and the printed insurance report and trade sheet.
///
/// Read through `\.hidesPrices`, set once at the root from this setting. The screens that keep
/// their numbers set it back to `false` for their subtree, so the rule is visible where it's broken.
enum CollectingMode {
    static let storageKey = "collectingMode"

    /// For code outside a view hierarchy — the widget snapshot writer.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: storageKey) }
}

extension EnvironmentValues {
    /// True in collecting mode: this surface shows no values or price changes. See `CollectingMode`.
    @Entry var hidesPrices: Bool = false
}

extension View {
    /// A screen whose job is money — trading, the wishlist, a printed report — keeps its numbers
    /// in collecting mode.
    func keepsPrices() -> some View { environment(\.hidesPrices, false) }
}
