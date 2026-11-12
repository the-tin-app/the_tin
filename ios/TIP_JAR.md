# Tip jar

Settings → Support → **Leave a tip**. Sold through RevenueCat; nothing in the app changes
whether or not someone tips (see `PRODUCT.md`). There is no entitlement check anywhere, by design.

The row appears only when `AppConfig.revenueCatAPIKey` is set **and** the current offering loads
with at least one package. A fork with no key builds and runs without it.

## One-time setup

1. **App Store Connect** → The Tin → In-App Purchases. Create:
   - three **Consumable** products, e.g. `tip.small` ($2.99), `tip.medium` ($4.99), `tip.large` ($9.99);
   - optionally one **auto-renewable subscription** (`tip.monthly`, $2.99/mo) in its own group.
   Each needs a display name, a description and a review screenshot of the Tip jar screen.
2. **RevenueCat** → new project → add the iOS app (bundle id) → paste the App Store Connect
   in-app purchase key (ASC → Users and Access → Integrations → In-App Purchase).
3. In RevenueCat, import the products, then create an **Offering**, mark it **Current**, and add one
   package per product. The app shows whatever is in the current offering, so changing amounts
   later is a dashboard edit, not a release.
4. Copy the **public SDK key** (`appl_…`) into `AppConfig.revenueCatAPIKey`
   (`ios/TheTin/Sources/Catalog/CatalogRemote.swift`). It is public by design.
5. Ship a build with the in-app purchases attached to the version in App Store Connect.

## Privacy

RevenueCat runs with an anonymous app user ID (we never call `logIn`). Update the App Store
privacy answers to declare **Purchases** (not linked to identity, not used for tracking) before
the first build with a key.

## Testing

Use a sandbox tester or an Xcode StoreKit configuration with the same product ids. `TipJarModel`
is covered by `TipJarModelTests` against a fake `TipStore`; the RevenueCat adapter itself is
not unit-tested.

## Where tips are mentioned

Nowhere in the app's chrome. The always-on "Support the project" bar on the Tin page is gone. A
`SupportNote` appears only inside four screens, after the app has just done something useful:
filing a scan batch, wishlist price drops (Watching), the portfolio value chart, and My Cards
movers. `SupportPromptModel` is the single gate:

- one note a week across all screens; showing it spends the slot, so ignoring it = a week of quiet
- ✕ = 30 days; a completed tip = 180 days
- never when the offering hasn't loaded, never at launch, never modal

The cost figures shown to people live in `SupportCosts` (`SupportPrompt.swift`); update them there
when the bill changes.
