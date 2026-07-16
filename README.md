# The Tin

**A free, open source collector app — for collectors, by collectors.**

The Tin is an iOS app for tracking a Pokémon TCG collection: scan cards with the
camera (entirely on-device), organize them into groups, follow their market value
over time, and know what your collection is worth — without ads, subscriptions,
or your collection leaving your phone.

## Why "The Tin"?

Every Pokémon kid had one: the tin. The binder held the bulk, but the tin held
the *loved* cards — the holos, the reverse holos, the EXes, the ones that got
played with and traded and looked at a hundred times. Above the binder in the
hierarchy of the heart.

This app is that tin, digitized.

## Goal

Collection trackers keep drifting toward paywalls: the scanner is metered, price
history is premium, the export button costs a subscription. The Tin's goal is a
collector-grade tracker where everything works, free, forever:

- **Free, with no feature gates.** No ads, no premium tier, no scan limits.
- **Private and offline-first.** Your collection lives on your device. Card
  recognition runs entirely on-device — photos of your cards are never uploaded.
- **Community funded, in the open.** Running costs are covered by donations with
  a public ledger. Money and code are both welcome; neither buys influence.
- **Open source.** The app and its backend are AGPL-3.0 — inspect it, fork it,
  self-host it.

## Status & roadmap

The Tin is currently in beta on iOS via TestFlight — **we're looking for beta
testers!** If you'd like to help shake out bugs before the 1.0 release,
[open an issue](../../issues) introducing yourself and we'll get you an invite.

Once version 1.0 ships on the iOS App Store, the next step is an Android
translation of the app, released on Google Play.

## Features

### Collection
- **Your tin, organized** — group cards however you collect (sets, decks, boxes,
  binders), with per-group stats and totals.
- **Wishlist** — track the cards you're hunting, separate from what you own.
- **Variants and conditions** — normal, holo, reverse holo; condition per copy;
  price paid vs. market value.
- **CSV import and export** — your data is yours; get it in and out in plain CSV.

### Scanning
- **On-device card scanner** — point the camera at a card and it's recognized in
  seconds, including holos and cards in binder pockets.
- **No cloud, no limits** — recognition combines on-device OCR with a downloadable
  visual fingerprint pack, so scanning works offline and no image ever leaves
  your phone.
- **Batch-friendly flow** — scans land in a staging tray to review, adjust
  variant/condition, and route to a group in bulk.

### Prices & portfolio
- **Market prices** — USD prices for every card, from open TCG data
  sources, refreshed daily.
- **Price history** — sparkline trends per card and portfolio value history for
  your whole collection.
- **Condition & graded pricing** — per-condition prices and PSA graded prices
  (funded by community donations), plus population data.
- **Grading ROI** — see whether grading a card is worth it before you send it in.
- **Sealed products** — track tins, ETBs, and booster boxes, not just singles.

### Browse & discover
- **Full card catalog** — browse and search every set, with a Pokédex view to
  explore by Pokémon.
- **Discover streams** — For You, chase cards, and full-art streams, recommended
  by on-device affinity (your taste data stays local).

### Reports & extras
- **Insurance report** — generate a printable PDF of your collection with values,
  for insurance or records.
- **Print sheets** — binder-style sheets of your cards for printing.
- **Home screen widget** — collection value at a glance.
- **Light / dark / system appearance.**

## What's in this repository

| Directory | What it is |
|---|---|
| `ios/` | The SwiftUI app (Xcode project generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `ios/project.yml`) |
| `catalog-server/` | Self-hostable catalog server — a thin, App Attest–gated static file server (Docker) that serves the card catalog and scanner fingerprint pack |
| `functions/` | The catalog data pipeline (Docker, `Dockerfile.pipeline`) — nightly build of the card-catalog SQLite from open data feeds, price enrichment, and 3-tier packaging/publishing |
| `fingerprint/` | The scanner's fingerprint pipeline — builds the visual recognition pack (ORB descriptors + vector-quantized codebook) from catalog card images |
| `test_images/` | Real card photos used by the scanner's accuracy evaluation (`test_images/images.csv` holds the ground-truth labels) |

Card metadata and raw prices come from open data sources —
[TCGdex](https://tcgdex.dev), [tcgcsv](https://tcgcsv.com) (TCGplayer USD), and
Cardmarket EUR trends. Graded prices and population data come from a commercial
API, paid for by community funding.

## Building the app

```bash
brew install xcodegen
cd ios
xcodegen generate
open TheTin.xcodeproj
```

The app builds and runs without any secrets. Firebase-backed extras (mirrored
card images, the hosted catalog fallback) need your own Firebase project and a
`GoogleService-Info.plist` (gitignored — the app treats it as optional).

Backend tests:

```bash
cd catalog-server && npm install && npm test   # catalog server
cd fingerprint && pytest                        # fingerprint pipeline
```

## Contributing

Bug reports, card data corrections, and small focused PRs are all welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md). Changes land through pull requests only;
please open an issue before starting anything large.

## License

Code is licensed under [AGPL-3.0](LICENSE). The name "The Tin", the app icon,
and the App Store presence are not part of the license — see
[TRADEMARK.md](TRADEMARK.md). If you distribute a modified version, rebrand it.

The Tin is an independent fan project. It is not affiliated with, endorsed by,
or sponsored by Nintendo, The Pokémon Company, or Creatures Inc. Pokémon and all
card images and names are trademarks of their respective owners.
