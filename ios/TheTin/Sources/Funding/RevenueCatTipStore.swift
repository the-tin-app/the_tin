import Foundation
import RevenueCat

/// RevenueCat-backed `TipStore`. The products are whatever the dashboard's **current offering**
/// contains, so adding or retiring a tip amount is a dashboard edit, not an app release.
///
/// RevenueCat runs here with an anonymous app user ID — we never call `logIn`, so no account,
/// email or device identifier of ours is attached to a purchase.
final class RevenueCatTipStore: TipStore, @unchecked Sendable {
    private let lock = NSLock()
    private var packages: [String: Package] = [:]

    /// Configures the SDK once. Call only with a non-empty public SDK key.
    static func configure(apiKey: String) {
        Purchases.configure(withAPIKey: apiKey)
    }

    func options() async throws -> [TipOption] {
        let offerings = try await Purchases.shared.offerings()
        guard let current = offerings.current else { return [] }
        var byID: [String: Package] = [:]
        let options = current.availablePackages.map { package -> TipOption in
            let product = package.storeProduct
            byID[package.identifier] = package
            return TipOption(id: package.identifier,
                             title: product.localizedTitle,
                             price: product.localizedPriceString,
                             isRecurring: product.subscriptionPeriod != nil,
                             sortValue: product.price)
        }
        lock.lock(); packages = byID; lock.unlock()
        return options
    }

    func purchase(_ option: TipOption) async throws -> TipOutcome {
        lock.lock(); let package = packages[option.id]; lock.unlock()
        guard let package else { throw TipError.unknownOption }
        let result = try await Purchases.shared.purchase(package: package)
        return result.userCancelled ? .cancelled : .thanked
    }

    enum TipError: Error { case unknownOption }
}
