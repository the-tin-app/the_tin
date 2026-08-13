---
name: The Tin
description: A free, open source Pokémon TCG collection tracker for iOS — clean, capable, quiet.
colors:
  tin-blue: "#3B74C9"
  tin-lid: "#5D90DD"
  tin-shadow: "#16386F"
  card-gold: "#EEBB62"
  card-gold-deep: "#D99F3D"
  cover-manila: "#E8D6A3"
  cover-sky: "#A8C7E0"
  cover-sage: "#B5C9A8"
  cover-clay: "#D9A699"
  cover-plum: "#BAA3C9"
  cover-sand: "#D9CCB5"
  cover-teal: "#94C4BF"
  cover-rose: "#DBABBF"
typography:
  display:
    fontFamily: "SF Pro Display, -apple-system, system-ui"
    fontSize: "34pt (Large Title, Dynamic Type)"
    fontWeight: 700
  headline:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "17pt (Headline, Dynamic Type)"
    fontWeight: 600
  title:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "15pt (Subheadline, Dynamic Type)"
    fontWeight: 600
  body:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "17pt (Body, Dynamic Type)"
    fontWeight: 400
  label:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "12pt / 11pt (Caption / Caption 2, Dynamic Type)"
    fontWeight: 400
rounded:
  sm: "6px"
  md: "8px"
  lg: "12px"
  pill: "9999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
---

# Design System: The Tin

## 1. Overview

**Creative North Star: "The Well-Kept Tin"**

A cared-for container: plain and sturdy on the outside, treasure on the inside. The
chrome IS the tin — neutral, system-native, unremarkable by design — and the cards are
the treasure it exists to hold. Every screen is built from stock iOS parts (tab bar,
navigation stacks, grouped lists, system controls) so a fluent iPhone user never pauses
at an off-spec control; identity is spent in small, deliberate places: the tin glyph and
its loading animation, the pastel group covers, the pink wishlist heart.

The system is quiet with warm edges. Density runs collector-grade — captions, footnotes,
and monospaced digits carry a lot of data per screen — but warmth is allowed at the
edges where the collection shows through. It explicitly rejects paywall-tracker vibes
(nothing may ever look locked or metered), finance-app coldness (prices serve the
collection, not the other way around), web-app-in-a-wrapper chrome, and kiddie Pokémon
kitsch.

**Key Characteristics:**
- Stock HIG structure everywhere; custom drawing reserved for the tin glyph
- Semantic system colors and system blue tint; brand palette confined to brand moments
- Dynamic Type only — no hard-coded body sizes; dense caption-level data presentation
- Flat chrome; depth via system materials — only card art, as a physical object, casts shadows
- Dark Mode and Reduce Motion are first-class, not afterthoughts

## 2. Colors

A restrained system palette with one small, literal brand family: the blue tin and the
gold card inside it.

### Primary
- **Tin Blue** (#3B74C9): the tin's enamel body. Appears in the tin glyph and app icon;
  interactive tint remains **system blue** so it adapts to Dark Mode and accessibility
  settings.
- **Tin Lid** (#5D90DD): highlight edge of the lid in the tin glyph's gradient.
- **Tin Shadow** (#16386F): the tin's dark underside; gradient anchor.

### Secondary
- **Card Gold** (#EEBB62) and **Card Gold Deep** (#D99F3D): the treasured card rising
  out of the tin. Used only inside the tin glyph — gold is the treasure, so it stays
  rare.

### Tertiary
- **The eight group covers** — Manila (#E8D6A3), Sky (#A8C7E0), Sage (#B5C9A8), Clay
  (#D9A699), Plum (#BAA3C9), Sand (#D9CCB5), Teal (#94C4BF), Rose (#DBABBF): muted
  pastel cover colors assigned to collection groups. The one place broad color is
  allowed; they read as binder covers, not UI chrome.
- **Semantic accents**: system green = owned, system pink = wishlist/support heart,
  system teal = NM price series, system orange = PSA 10 series, system gray = cost
  basis. Keyed consistently — a series color never changes meaning between chart and
  legend.

### Neutral
- **System semantic colors** (label, secondaryLabel, tertiaryLabel, systemBackground,
  separator) everywhere. No raw hex in chrome; the system palette carries Dark Mode and
  increased-contrast for free.

### Named Rules
**The Plain Tin Rule.** Brand color lives in the tin glyph and app icon only. Screen
chrome uses semantic system colors plus the single system-blue tint; if a screen looks
"branded", it's wrong.

**The Treasure Rule.** Card art is the color of the app. Around imagery, chrome goes
neutral — never compete with a holo.

## 3. Typography

**Display Font:** SF Pro Display (system)
**Body Font:** SF Pro Text (system)
**Accent Font:** New York (system serif), italic — the "penned label" voice
**Money Font:** SF Rounded (system, `design: .rounded`), bold — hero currency values only
**Numeric style:** monospaced digits for every price, count, and percentage

**Character:** San Francisco through Dynamic Type text styles — no third-party faces,
no hard-coded sizes. Hierarchy comes from weight (semibold emphasis) and the secondary/
tertiary color axis rather than from size jumps. One sanctioned accent: New York serif
italic as the handwritten-index-card voice, used only where the tin metaphor is physical
(divider tab labels, the pager's title plaque) — never in controls, data, or body text.

### Hierarchy
- **Display** (bold, Large Title 34pt): top-level screen titles, collapsing to inline
  on scroll.
- **Headline** (semibold, 17pt): row titles, card names, section leads.
- **Title** (semibold/medium, Subheadline 15pt): grouping labels, emphasized row data.
- **Body** (regular, 17pt): prose and form content.
- **Label** (regular, Caption 12pt / Caption 2 11pt, usually `.secondary`): the data
  layer — prices, dates, counts, "as of" stamps, meter labels. The workhorse of the app.

### Named Rules
**The Caption Ledger Rule.** Collection data runs dense and small: caption-level type,
secondary color, monospaced digits, always with provenance ("as of [date]"). Precision
is stated quietly, never dramatized.

**The Dynamic Type Rule.** System text styles only. A hard-coded point size on text is
a defect except in fixed-canvas contexts (print/PDF report pages, the drawn tin glyph).

**The Penned Label Rule.** New York serif italic is the one sanctioned accent face —
the handwritten index-card voice, used only where the tin metaphor is physical (divider
tabs, the pager title plaque). Never in controls, data, or body text.

**The Money Face Rule.** SF Rounded, bold, monospaced digits is the sanctioned face for
hero currency values — the tin total, a pager card's value, the portfolio headline. One
number per screen wears it; caption-ledger prices stay SF Pro. Rounded is the warmth of
the number, never a display face for text.

## 4. Elevation

Flat by doctrine. Chrome does not cast shadows; depth is conveyed by system materials —
`.thinMaterial` for persistent overlays (funding bar, staging surfaces),
`.ultraThinMaterial` for floating badges over card art — and by system background
layering (systemBackground vs. secondarySystemBackground). Sheets and navigation get
their depth from UIKit's own transitions.

### Named Rules
**The Flat Tin Rule.** No `.shadow()` on chrome. Card art is the one exception: a card
is a physical object held above the surface, and may cast a soft contact shadow
(riffle spreads, the pager's hero art). Buttons, bars, tiles, and text never do — if a
chrome layer needs separation, it earns a system material or a background-level shift.

## 5. Components

Stock and quiet, with warm edges: system controls as-is, personality confined to small
custom pieces documented here.

### Buttons
- **Primary:** system `.borderedProminent`, system-blue tint, `.small` control size in
  bars (e.g. the "Support" button). Never custom-drawn.
- **Plain/utility:** `.plain` button style with secondary foreground for chevrons and
  incidental actions.
- **States:** system-provided (pressed, disabled); no custom state styling.

### Chips / Badges
- **CardBadges**: caption2 SF Symbols in a capsule of `.ultraThinMaterial`, 3pt padding
  — green `checkmark.circle.fill` = owned, pink `heart.fill` = wanted. Floats over card
  art without blocking it.

### Cards / Containers
- **Corner style:** 12px radius for content tiles (dominant), 8px for smaller nested
  elements, capsule for meters and badges.
- **Group covers:** flat pastel fill from the eight-cover deck, no border, no shadow.
- **Card imagery:** the card itself is the container — shown at full bleed with its own
  corner radius, never framed in a decorated card.

### Inputs / Fields
- System forms and grouped/inset list style for settings-shaped content. System
  searchable modifier for search. No custom text-field chrome.

### Navigation
- Five-tab `TabView` (Discover / Browse / Search / The Tin / Scan) with SF Symbols;
  `NavigationStack` per tab; large titles at top level, inline when deep. Sheets for
  self-contained tasks; edge-swipe back always alive.

### The Tin Glyph (signature component)
`TinIcon` / `TinLoadingView`: the hand-drawn tin in Tin Blue → Tin Shadow gradients
with a Card Gold card inside. The loading loop (lid opens, card rises, settles shut,
2.8s) replaces `ProgressView` at main loading moments; Reduce Motion gets a static
open-tin pose. This is the app's one theatrical moment — don't add others.

### The Funding Bar (signature component)
Never-blocking support strip on `.thinMaterial`: collapsed to a single caption line by
default, expanding to a capsule progress meter + small prominent "Support" button.
Nothing in the app is gated by it, and its copy must never imply a donation unlocks
anything.

**The Tin tab only.** It was on all five tabs and every screen pushed from them, which
spent ~24pt off the top of the entire app — including the scanner viewfinder and search
results, where the relationship it asks about is not what the user is doing. It lives
where the collection lives; Settings carries the full Support section for everywhere
else. Generosity is visible in the design, not repeated on every screen.

**One banner above content, never a stack.** The offline and reduced-data notices could
both render, with the scanner-pack prompt above them as a third. Offline wins — it is the
one the user can't act on, and it dates the prices explicitly.

## 6. Lexicon

The app invents nouns — tin, divider, Movers, Watching, Hunting, Grail, the pack — and a
first-run report (2026-08-12) named six things a non-collector could not work out.
Four were naming and navigation defects, not missing explanation. This table is the
fix that stops the fifth: **one concept, one word, everywhere it appears.**

| Say | Never say | What it means |
|---|---|---|
| **Tin** | collection, library | Everything you own. The Tin tab, and the total on it. |
| **Divider** | group, folder, binder, tab | A named tray inside the tin. `CardGroup` is the type; nobody sees that word. |
| **Sealed** | box, product | Unopened product you own. Its own section, never a divider. |
| **Wishlist** | Wanted, Want List, wants | The door: cards and sets you're after. One screen, three segments. |
| **Sets** | set goals, collecting | Wishlist segment: sets you're completing, tracked as a gap. |
| **Singles** | wishlist cards | Wishlist segment: individual cards you chose, with a target and a priority. |
| **Hunting** | watching, searching | Wishlist segment: cards you are *actively buying*, with a budget and an eBay search. A hunt runs until switched off. |
| **Grail** | favourite, top pick | The card you'd most want, whether or not you're buying one now. A priority above High — **not** a hunt. |
| **Watching** | alerts, notifications | The **news**: what the cards you care about have been doing. Never a list of cards to act on — it links to Hunting, it does not repeat it. |
| **For Trade** | spares, duplicates | Copies you've said you'll part with. |
| **Movers** | trends, gainers | What prices did over the selected window — yours, or the market's. |
| **The pack** | scanner data, model | The downloadable fingerprint pack the camera scanner needs. |
| **Catalog** | database, card data | The offline card data. Downloaded in one of three **sizes**, never "tiers" in user copy. |

### Named Rules

**The One Name Rule.** A concept gets one user-facing spelling. The pinned row and the
screen it opens must say the same word — that failure shipped once, with one tap
producing three different screen titles depending on a persisted segment choice.

**The rename isn't done until the quotes are.** Renaming a screen does not rename the
places that quote it. "Want List" survived as the title of the printed wishlist PDF long
after the door was renamed. `VocabularyTests.banned` is the ratchet: add every retired
name to it, and the next one fails a test instead of a first run.

**Nothing may promise speed.** Hunting reaches the user through eBay's saved-search
email, which is daily. No copy — tip, footer, button, or notification — may imply faster.
`TipsTests.testNoTipPromisesSpeed` guards the tips; `HuntingListView`'s footer is the one
place that explains the mechanism.

**The shared page is the one surface outside this table.** `site/functions/l.js` writes its
own copy for a recipient who does not have the app — "2 cards wanted", not "Wishlist" —
and that is correct: a stranger is reading a list, not using your tin. It is also asserted
by `site/tests/shared-list.test.mjs`. The app's lexicon stops at the app.

`ShareList.Kind` carries no display name for that reason; it is the wire discriminator and
nothing else. It did carry one — `var title` returning "Want List", with no call sites at
all — and that is the shape this rule is really about: a retired name survives longest
where nothing reads it.

## 7. Do's and Don'ts

### Do:
- **Do** use semantic system colors and system controls everywhere; the chrome is the
  tin — plain, sturdy, adaptive.
- **Do** keep data provenance visible: prices carry "as of [date]" in caption2
  secondary, digits monospaced.
- **Do** confine brand color to the tin glyph and app icon (The Plain Tin Rule) and
  broad color to the eight group covers.
- **Do** honor Dynamic Type, VoiceOver labels, and Reduce Motion in every new view —
  the tin loading view is the reference implementation.
- **Do** design Dark Mode and Light Mode together; semantic colors make this free —
  keep it that way.

### Don't:
- **Don't** ship anything with *paywall-tracker vibes*: no locked features, "PRO"
  badges, upsell banners, or UI that even resembles a meter. The funding bar is a
  support ask, never a gate.
- **Don't** drift into *finance-app coldness*: charts and prices serve the collection;
  never lead a screen with a chart when the cards can lead.
- **Don't** build *web-app-in-a-wrapper* chrome: no custom nav bars, hamburger menus,
  web-shaped buttons, or reinvented system controls.
- **Don't** touch *kiddie Pokémon kitsch*: no Pikachu-yellow, cartoon fonts, or IP
  cosplay. The cards supply the Pokémon; the app supplies the tin.
- **Don't** add shadows to chrome (The Flat Tin Rule — card art may cast them),
  hard-code text sizes (The Dynamic Type Rule), or invent a second theatrical animation
  beyond the tin loading loop.
