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
Always-on, never-blocking support strip on `.thinMaterial`: collapsed to a single
caption line by default, expanding to a capsule progress meter + small prominent
"Support" button. Nothing in the app is gated by it, and its copy must never imply a
donation unlocks anything.

## 6. Do's and Don'ts

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
