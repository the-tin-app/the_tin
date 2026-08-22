<h1 align="center">The Tin</h1>

<p align="center">
  <strong>A free, open source collector app — for collectors, by collectors.</strong><br>
  Scan a card, know what it's worth, keep your collection yours.
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6788516920">
    <img src="site/assets/app-store-badge.svg" alt="Download on the App Store" height="56">
  </a>
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6788516920"><img alt="App Store" src="https://img.shields.io/badge/iOS-App%20Store-0D96F6?logo=apple&logoColor=white"></a>
  <img alt="License" src="https://img.shields.io/badge/license-AGPL--3.0-blue">
  <img alt="Platform" src="https://img.shields.io/badge/iOS-17.0%2B-lightgrey">
  <img alt="Price" src="https://img.shields.io/badge/price-free%20forever-brightgreen">
</p>

<p align="center">
  <img src="site/assets/shot-scan.jpg" alt="Scanning a card with the camera" width="20%">
  <img src="site/assets/shot-tin.jpg" alt="A collection organized into dividers, priced daily" width="20%">
  <img src="site/assets/shot-prices.jpg" alt="Raw, condition and graded prices for one card" width="20%">
  <img src="site/assets/shot-grade.jpg" alt="Price history and the grading-ROI estimate" width="20%">
</p>

> Card artwork and card names are blurred in these captures. The app itself shows them
> normally — see [Trademarks & fair use](#license) for why.

---

**No ads. No paywall. No subscription. No account.** Every competitor meters something —
the scanner, price history, the export button. The Tin doesn't, and the code is here so
you can check.

The Tin is an iOS app for tracking a trading card collection: scan cards with the
camera (entirely on-device), organize them into groups, follow their market value
over time, and know what your collection is worth — without ads, subscriptions,
or your collection leaving your phone.

**[⬇︎ Download on the App Store](https://apps.apple.com/app/id6788516920)** · iOS 17+, iPhone and iPad

## Why "The Tin"?

Every kid who collected had one: the tin. The binder held the bulk, but the tin held
the *loved* cards — the holos, the reverse holos, the EXes, the ones that got
played with and traded and looked at a hundred times. Above the binder in the
hierarchy of the heart.

This app is that tin, digitized.

## Goal

Collection trackers keep drifting toward paywalls: the scanner is metered, price
history is premium, the export button costs a subscription. The Tin's goal is a
collector-grade tracker where everything works, free, forever:

- **Free, with no feature gates.** No ads, no premium tier, no scan limits.
- **Private and offline-first.** Your collection lives on your device, backed up
  to your own iCloud so a new phone can restore it — never to a server of ours.
  Card recognition runs entirely on-device; camera frames never leave the phone.
- **Community funded, in the open.** Running costs are covered by
  [GitHub Sponsors](https://github.com/sponsors/treyes133); what they pay for is
  itemized in [SPONSORS.md](SPONSORS.md). Money and code are both welcome;
  neither buys influence.
- **Open source.** The app and its backend are AGPL-3.0 — inspect it, fork it,
  self-host it.

## Status & roadmap

**The Tin is live on the App Store** — iPhone and iPad, iOS 17+. v1.0 shipped
2026-07-31; 1.0.3 is the current public release.
[Download it here](https://apps.apple.com/app/id6788516920).

Next up: multi-device sync, trading tools, and an Android translation of the app
on Google Play. (Sync was prototyped over CloudKit and abandoned — see
[#97](../../pull/97) — so the shipping design is end-to-end-encrypted blobs the
app uploads itself, which is also what makes an Android client possible.) Bugs
and feature requests are welcome in [issues](../../issues) — early reports get
acted on fast.

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
- **Sealed products** — see market prices for tins, ETBs, and booster boxes
  alongside each set.

### Browse & discover
- **Full card catalog** — browse and search every set, with a Dex view to
  explore by creature.
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
| `catalog-server/` | Self-hostable catalog server — a thin, App Attest–gated static file server (Docker) that serves the card catalog and scanner fingerprint pack ([setup](catalog-server/README.md)) |
| `functions/` | The catalog data pipeline (Docker, `Dockerfile.pipeline`) — nightly build of the card-catalog SQLite from open data feeds, price enrichment, and 3-tier packaging/publishing (configuration in [`.env.example`](functions/.env.example)) |
| `fingerprint/` | The scanner's fingerprint pipeline — builds the visual recognition pack (ORB descriptors + vector-quantized codebook) from catalog card images |
| `test_images/` | Real card photos used by the scanner's accuracy evaluation (`test_images/images.csv` holds the ground-truth labels) |
| `site/` | [thetinapp.com](https://thetinapp.com) — the static marketing, privacy and support pages, plus the Cloudflare Pages Functions behind share links (`/c/`, `/l`) |
| `workers/` | `tin-backup`, a Cloudflare Worker that serves the catalog and fingerprint pack from R2 as a second origin when the primary server is down |

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

### Tests

Six suites, all runnable from a fresh clone. CI runs the five non-iOS ones on
every pull request (`.github/workflows/ci.yml`).

```bash
cd functions        && npm ci && npm test              # catalog data pipeline
cd catalog-server   && npm ci && npm test              # catalog server
cd workers/tin-backup && npm ci && npm test            # R2 backup origin
cd site             && node --test tests/*.test.mjs    # share-link Functions (no deps)
```

The fingerprint pipeline needs **Python 3.11 specifically** — the pinned
`opencv-python-headless` has no wheel for newer Pythons, and building it from
source is impractical:

```bash
cd fingerprint
python3.11 -m venv .venv && . .venv/bin/activate
pip install -e ".[dev]"
pytest
```

The iOS suite runs from Xcode (⌘U) or `xcodebuild test`. On a memory-constrained
Mac add `-parallel-testing-enabled NO`; the test hosts get killed otherwise and
the run reports zero tests rather than a failure.

## Contributing

Bug reports, card data corrections, and small focused PRs are all welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md). Changes land through pull requests only;
please open an issue before starting anything large.

## Branching & releases

The repo follows a three-tier branch doctrine:

```
feat|fix|chore|perf|docs/* ──PR──▶ staging ──promote/X.Y.Z-to-main──▶ main
```

- **`main` — App Store releases.** Only ever updated by a promotion PR, never
  pushed to directly. Each release is tagged on the exact commit Apple approved
  (`v1.0.3`).
- **`staging` — the open TestFlight train.** The long-lived integration branch
  internal testers run. Every TestFlight upload is archived from `staging` and
  tagged with its version and build number (`vX.Y.Z-buildN`), so any commit can
  be traced to the build testers are holding.
- **Work branches** — `feat/`, `fix/`, `chore/`, `perf/` or `docs/` prefixed.
  All work happens here and rolls into `staging` through pull requests. Branch
  from `staging`, never from `main`.
- **`staging-X.Y.Z` — the next train, when two are open at once.** An App Store
  version stops accepting new builds the moment it enters review, so when that
  happens `staging` stays on the version under review (leaving room for a fix
  review demands) and the next version's work collects on `staging-X.Y.Z` until
  the outgoing train closes.

**Promotion:** once a version is approved and live on the App Store, its commit
is promoted to `main` through a `promote/X.Y.Z-to-main` pull request and tagged
as a release.

## License

Code is licensed under [AGPL-3.0](LICENSE). The name "The Tin", the app icon,
and the App Store presence are not part of the license — see
[TRADEMARK.md](TRADEMARK.md). If you distribute a modified version, rebrand it.

### Trademarks & fair use

The Tin is an independent fan project. It is not affiliated with, endorsed by,
or sponsored by Nintendo, The Pokémon Company, or Creatures Inc. Pokémon and all
card images and names are trademarks of their respective owners, used here only
to identify the cards a collector owns.

Card artwork and card names are blurred in the screenshots above and in the App
Store listing. The app displays them normally — a collection tracker that can't
show you your cards would be useless. The blurring is a deliberate choice about
*promotional* material, not a limitation of the app.
