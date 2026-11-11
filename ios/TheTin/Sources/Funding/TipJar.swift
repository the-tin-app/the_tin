import Foundation
import Observation

/// One thing a person can buy to say thanks. Built from a store product, but carries only what
/// the UI needs so the screen and its tests never touch the SDK.
struct TipOption: Identifiable, Equatable {
    let id: String
    let title: String
    /// Already localized by the store ("$2.99"), never formatted by us.
    let price: String
    /// A subscription renews monthly; everything else is a one-off.
    let isRecurring: Bool
    /// Raw price, only used to order the list cheapest-first.
    let sortValue: Decimal
}

enum TipOutcome: Equatable { case thanked, cancelled }

/// The seam between the tip jar and whatever sells the products. The real one wraps RevenueCat;
/// tests use a fake, so no test needs the SDK or a network.
protocol TipStore: Sendable {
    func options() async throws -> [TipOption]
    func purchase(_ option: TipOption) async throws -> TipOutcome
}

/// Drives the tip jar screen.
///
/// **Nothing is unlocked, ever.** A tip changes no state in the app — not a badge, not a hidden
/// setting, not "supporter" in a stored flag. That is what PRODUCT.md promises, and it is why
/// there is deliberately no entitlement check anywhere in this file. A successful purchase ends
/// in a thank-you line and nothing else.
@MainActor @Observable
final class TipJarModel {
    enum State: Equatable {
        case idle
        case loading
        case ready([TipOption])
        /// No store, offerings couldn't be fetched, or there are none. The row stays out of the way.
        case unavailable
    }

    enum Banner: Equatable { case thanks, failed }

    private(set) var state: State = .idle
    private(set) var purchasing: String?
    private(set) var banner: Banner?
    private let store: TipStore?

    /// `nil` store ⇒ no key configured (an open-source build with no RevenueCat project). The
    /// model then reports `.unavailable` and Settings never shows the row.
    init(store: TipStore?) {
        self.store = store
    }

    /// Cheap and idempotent: only the first call (or one after a failure) hits the network.
    func load() async {
        guard let store else { state = .unavailable; return }
        if case .ready = state { return }
        if case .loading = state { return }
        state = .loading
        do {
            let list = try await store.options().sorted { $0.sortValue < $1.sortValue }
            state = list.isEmpty ? .unavailable : .ready(list)
        } catch {
            state = .unavailable
        }
    }

    func tip(_ option: TipOption) async {
        guard let store, purchasing == nil else { return }
        purchasing = option.id
        banner = nil
        defer { purchasing = nil }
        do {
            switch try await store.purchase(option) {
            case .thanked: banner = .thanks
            case .cancelled: break   // They changed their mind. Not an error, not worth a message.
            }
        } catch {
            banner = .failed
        }
    }

    func dismissBanner() { banner = nil }

    /// Whether Settings should offer the screen: only once there is something to buy.
    var isAvailable: Bool {
        if case .ready = state { return true }
        return false
    }
}
