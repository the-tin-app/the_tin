/**
 * Cards that exist on TCGplayer but NOT in tcgdex/cards-database.
 *
 * The catalog's card universe has always been TCGdex alone; every other feed (tcgcsv, PPT,
 * Cardmarket) is price-only and joins onto a card that must already exist. So a card TCGdex
 * hasn't published can never appear no matter how well-priced it is upstream — that is how
 * MEP Black Star Promos 046-054 (the gen-2/5/8 starter promos) were missing while TCGplayer
 * had them priced. Worse, the completeness check couldn't see it: `set_info.total` is copied
 * from the same stale TCGdex record, so the set reported 60/60 while holding 60 of 88.
 *
 * This module fills those holes from the tcgcsv product feed we already sweep for prices.
 * Everything here is pure — the caller does the fetching.
 *
 * The two hard parts, both learned by running this against the real feed:
 *
 *   1. tcgcsv groups carry no set id, so the group→set mapping is DERIVED from productIds we
 *      already resolve (see `mapGroupsToSets`). Self-calibrating, nothing to hand-maintain.
 *   2. A promo group is full of reprints numbered by their ORIGINAL set ("Dark Gyarados 8/82"
 *      filed under Celebrations Classic Collection). Those are not holes, and creating them
 *      would have added 22 duplicates to a set that was already complete. `denominatorFits`
 *      is the guard; see the comment on it.
 *
 * ⚠️ Deriving the mapping from productIds has a blind spot, and it is NOT the one the guards
 * are about: a set where NOT ONE card carries a tcgplayer id resolves zero products, votes for
 * nothing, and is rejected `no-matches` before either guard is consulted. Loosening the guards
 * cannot reach it — there is nothing to threshold. Measured on the live feed: `sma` (Hidden
 * Fates Shiny Vault, 94 cards) and `bwp` (BW Black Star Promos, 101) are both 0-linked, and
 * catalog-wide ~4,092 of 23,548 cards carry no tcgplayer id, so they get no TCGplayer price
 * either. `cardsByNameNumber` is the second, weaker key that breaks that circle — see
 * `resolveByNameNumber`. It does NOT reach a set we don't have at all (Trading Card Game
 * Classic); that is a different problem and needs a set to be created, not matched.
 */
import type { TcgdexAttack, TcgdexDetail } from "../upstream/tcgdex";

/**
 * Structural match for `FlatCard` in scripts/flatten-cards-db.ts. Declared here rather than
 * imported because `src/` is the tsc rootDir and may not reach into `scripts/`; the assignment
 * in build-catalog.ts is what type-checks the two against each other.
 */
export interface SynthesizedCard {
  id: string;
  setId: string;
  serieId: string | null;
  localId: string;
  name: string;
  hp: number | null;
  types: string[];
  rarity: string | null;
  artist: string | null;
  text: string;
  attacks: TcgdexAttack[];
  detail?: TcgdexDetail;
  tcgplayerIds: number[];
  tcgplayerByType: [string, number][];
  cardmarketIds: number[];
  dexId: number[];
}

export interface TcgcsvProduct {
  productId: number;
  name: string;
  imageUrl?: string | null;
  extendedData?: { name: string; value: string }[];
}

/** A group with too few resolved products can't vote credibly — "Jumbo Cards" matched exactly
 *  ONE product and would otherwise have claimed `svp` at 100% confidence, inventing 173 cards. */
const MIN_MATCHED_PRODUCTS = 10;
const MIN_DOMINANT_SHARE = 0.8;

const ENERGY_BY_LETTER: Record<string, string> = {
  G: "Grass", R: "Fire", W: "Water", L: "Lightning", P: "Psychic", F: "Fighting",
  D: "Darkness", M: "Metal", C: "Colorless", Y: "Fairy", N: "Dragon",
};
const CARD_TYPES = new Set(Object.values(ENERGY_BY_LETTER));

export function extMap(p: TcgcsvProduct): Record<string, string> {
  const out: Record<string, string> = {};
  for (const e of p.extendedData ?? []) if (e?.name) out[e.name] = e.value ?? "";
  return out;
}

/**
 * Every form a card number could be written as, so a candidate matches an existing card when
 * ANY key collides. The same physical card is "SVP193" on TCGplayer and "193" in the catalog,
 * or "226/S-P" vs "SWSH226" — comparing raw strings reports both as missing.
 */
export function numberKeys(raw: string | null | undefined): Set<string> {
  const head = (raw ?? "").split("/")[0].trim().toUpperCase();
  if (!head) return new Set();
  const keys = new Set<string>([head]);
  const stripped = head.replace(/^0+/, "");
  if (stripped) keys.add(stripped);
  const prefixed = /^([A-Z]+)[ -]?0*(\d+)$/.exec(head);
  if (prefixed) { keys.add(prefixed[2]); keys.add(prefixed[1] + prefixed[2]); }
  return keys;
}

/**
 * A printed denominator that belongs to a DIFFERENT set means this product is a reprint filed
 * under a promo group, not a hole in this set — "Dark Gyarados 8/82" under Celebrations Classic
 * Collection is Neo Genesis' numbering, and cel25cc was already complete at 25/25.
 *
 * Accepts both `total` and `printedTotal` because secret rares push `total` past the printed
 * count either way round: Aquapolis prints "128/147" while its total is 185, and that card
 * (Memory Berry) is a genuine hole.
 */
export function denominatorFits(raw: string | null | undefined, total: number | null, printedTotal: number | null): boolean {
  const parts = (raw ?? "").split("/");
  if (parts.length < 2) return true; // no denominator printed — nothing to contradict
  const d = parts[1].trim().replace(/^0+/, "");
  if (!d || !/^\d+$/.test(d)) return true; // "226/S-P" and friends carry no numeric claim
  return d === String(total ?? "") || d === String(printedTotal ?? "");
}

/**
 * `[GC] Razor Leaf (30)<br> Flip a coin…` → name/damage/cost + the effect text after the <br>.
 *
 * The cost bracket also carries DIGITS for colorless ("[3] Victory Symbol", "[1P] Hypnostrike").
 * Rejecting those didn't just lose the cost — it left "[3] " glued to the attack NAME, which is
 * the field FTS indexes, so the card became unfindable by its own attack.
 */
export function parseAttack(value: string): { name: string; damage: string | null; cost: string[]; effect: string } | null {
  const [head, ...rest] = value.split(/<br\s*\/?>/i);
  const m = /^\s*(?:\[([A-Z0-9]*)\])?\s*(.+?)\s*(?:\(([^)]*)\))?\s*$/.exec(head ?? "");
  if (!m || !m[2]) return null;
  const cost: string[] = [];
  for (const ch of m[1] ?? "") {
    if (ENERGY_BY_LETTER[ch]) cost.push(ENERGY_BY_LETTER[ch]);
    else if (/\d/.test(ch)) for (let i = 0; i < Number(ch); i++) cost.push("Colorless");
  }
  return { name: stripHtml(m[2]), damage: m[3]?.trim() || null, cost, effect: stripHtml(rest.join(" ")) };
}

/**
 * "Rx2" / "Fx2" / "Wx2" → `{ type: "Fire", value: "×2" }`; "F-30" → `{ type, value: "-30" }`.
 *
 * tcgcsv packs weakness and resistance as an energy LETTER followed by the printed modifier, which
 * is not the shape TCGdex uses. Returns undefined for anything that does not parse — these cards
 * are gap-fill, so a field we cannot read is a blank row on the sheet, never a wrong one.
 */
export function parseTypeValue(value: string | undefined): { type: string; value: string }[] | undefined {
  const m = /^\s*([A-Z])\s*(x\s*\d+|[-+]\s*\d+)\s*$/i.exec(value ?? "");
  const type = m ? ENERGY_BY_LETTER[m[1]!.toUpperCase()] : undefined;
  if (!m || !type) return undefined;
  return [{ type, value: m[2]!.replace(/\s+/g, "").replace(/^x/i, "×") }];
}

/** The detail blob for a gap-fill card, from whatever the tcgcsv `extendedData` happens to carry. */
export function pickCsvDetail(ext: Record<string, string>, hp: number | null): TcgdexDetail | undefined {
  const weaknesses = parseTypeValue(ext["Weakness"]);
  const resistances = parseTypeValue(ext["Resistance"]);
  const retreat = /^\d+$/.test(ext["RetreatCost"] ?? "") ? Number(ext["RetreatCost"]) : undefined;
  const text = stripHtml(ext["CardText"] ?? "");
  const detail: TcgdexDetail = {
    // HP is the only signal in this feed for "is this a Pokémon": a Trainer has none.
    category: hp != null ? "Pokemon" : "Trainer",
    ...(ext["Stage"] ? { stage: ext["Stage"] } : {}),
    ...(weaknesses ? { weaknesses } : {}),
    ...(resistances ? { resistances } : {}),
    ...(retreat != null ? { retreat } : {}),
    // A Pokémon's CardText is flavour; a Trainer's IS the rules text, and the sheet prints it
    // where a Pokémon's attacks go.
    ...(hp == null && text ? { effect: text } : {}),
  };
  return detail;
}

function stripHtml(s: string): string {
  return s.replace(/<[^>]+>/g, " ").replace(/&amp;/g, "&").replace(/&#39;|&rsquo;/g, "'")
    .replace(/&quot;/g, '"').replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim();
}

/** A card as seen by the weak key, for the sets whose cards carry no tcgplayer id. */
export interface CardRef { id: string; setId: string; linked: boolean }

/** The key of `SynthesizeInput.cardsByNameNumber`: a card name and ONE of its `numberKeys`. */
export function nameNumberKey(name: string, numberKey: string): string {
  return `${name.toLowerCase().replace(/[^a-z0-9]/g, "")}|${numberKey}`;
}

/**
 * Which set a product belongs to, judged by printed name + number instead of by productId.
 *
 * Weaker than the id, so it is only ever a fallback (see `mapGroupsToSets`) and it is deliberately
 * unforgiving: a key whose (name, number) pair exists in more than one set casts NO vote, and two
 * keys of the same product that disagree cancel each other. That matters because `numberKeys`
 * emits both the specific form and the bare digits — "SV49" identifies one card in `sma`, while
 * "49" is card 49 of every set ever printed. Punctuation is stripped on both sides: TCGdex writes
 * "Farfetch’d" and "Unown !" where TCGplayer writes "Farfetch'd" and "Unown (!)".
 */
export function resolveByNameNumber(p: TcgcsvProduct, index: Map<string, CardRef[]>): string | null {
  const ext = extMap(p);
  if (!("HP" in ext) && !("Card Type" in ext)) return null;
  const raw = ext["Number"];
  const name = cleanName(p.name, (raw ?? "").split("/")[0].trim());
  let found: string | null = null;
  for (const k of numberKeys(raw)) {
    const refs = index.get(nameNumberKey(name, k));
    if (!refs) continue;
    const setId = refs[0].setId;
    if (refs.some((r) => r.setId !== setId)) continue; // the key is ambiguous — no vote
    if (found && found !== setId) return null;         // two keys, two sets — no vote
    found = setId;
  }
  return found;
}

/**
 * The unlinked card in `setId` this product is, or null when that is not exactly one card.
 * Same key and same strictness as `resolveByNameNumber`, narrowed to the group's own set.
 */
function linkTarget(p: TcgcsvProduct, setId: string, index: Map<string, CardRef[]>, claimed: Set<string>): string | null {
  const ext = extMap(p);
  const raw = ext["Number"];
  const name = cleanName(p.name, (raw ?? "").split("/")[0].trim());
  const hits = new Set<string>();
  for (const k of numberKeys(raw)) {
    for (const r of index.get(nameNumberKey(name, k)) ?? []) {
      if (r.setId === setId && !r.linked && !claimed.has(r.id)) hits.add(r.id);
    }
  }
  return hits.size === 1 ? [...hits][0] : null;
}

// ---------------------------------------------------------------------------------------------
// Print runs — a card we ALREADY have, sold under a print run we do not model.
//
// The groups no set claims (World Championship Decks, Prize Pack Series, Trick or Trade, the
// promo junk drawers) are not full of missing cards: 5,574 of their 7,325 card products are a
// card we already hold, reprinted with a stamp or a different foil. They were invisible, and the
// collector who owns one was being shown the base card's price. These become extra
// `price_by_variant` rows on the card that already exists — no new card id, so nothing enters
// `wants.json` or the fingerprint pack.
// ---------------------------------------------------------------------------------------------

/** A card we already hold, sold in a group we cannot place. `printing` is a `price_by_variant` key. */
export interface PrintRun { cardId: string; groupId: number; productId: number; printing: string }

/**
 * The card a product IS, searched across the WHOLE catalog rather than one set.
 *
 * ⚠️ The global search is much weaker than `linkTarget`'s set-scoped one and needs the extra
 * guard: `numberKeys` emits the zero-stripped form alongside the printed one, so "Mewtwo
 * 010/102" matches promo `P-A-010` on the "010" key while the true `base1-10` only holds "10" —
 * measured, and it returned the promo. `denominatorFits` is what breaks the tie, and applying it
 * also RAISED the hit rate (5,294 → 5,574) because it un-ambiguates keys rather than only
 * rejecting them.
 */
export function resolveCardGlobally(
  p: TcgcsvProduct,
  index: Map<string, CardRef[]>,
  setTotals: Map<string, { total: number | null; printedTotal: number | null }>,
): string | null {
  const raw = extMap(p)["Number"];
  const name = printBaseName(p.name, raw).replace(/\s*[([][^)\]]*[)\]]\s*$/, "").replace(/\s+-\s+.*$/, "").trim();
  let found: string | null = null;
  for (const k of numberKeys(raw)) {
    const refs = (index.get(nameNumberKey(name, k)) ?? []).filter((r) => {
      const t = setTotals.get(r.setId);
      return denominatorFits(raw, t?.total ?? null, t?.printedTotal ?? null);
    });
    if (!refs.length) continue;
    const id = refs[0].id;
    if (refs.some((r) => r.id !== id)) continue; // the key is ambiguous — no vote
    if (found && found !== id) return null;      // two keys, two cards — no vote
    found = id;
  }
  return found;
}

/**
 * The product name with TCGplayer's trailing " - <number>" removed, in every form it writes it.
 *
 * `cleanName` only strips the localId ("Chikorita - 046"); the promo groups also write the full
 * printed fraction ("Kricketune V - 006/163"), which its `(?![\w/])` guard deliberately refuses.
 * Widening `cleanName` itself would change which cards get synthesized, so this is separate.
 */
export function printBaseName(productName: string, raw: string | null | undefined): string {
  const head = (raw ?? "").split("/")[0].trim();
  for (const form of [raw, head, /(\d+)$/.exec(head)?.[1]]) {
    if (!form) continue;
    const esc = form.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const next = productName.replace(new RegExp(`\\s+-\\s+0*${esc}\\s*$`, "i"), "");
    if (next !== productName) return next.replace(/\s+/g, " ").trim();
  }
  return productName.replace(/\s+/g, " ").trim();
}

/** The trailing "(Cosmos Holo)" / "[Staff]" that says which print this is. */
function printMarker(base: string): string | null {
  return /[([]([^)\]]+)[)\]]\s*$/.exec(base)?.[1].trim() ?? null;
}

/**
 * Every print run in the groups no set claimed.
 *
 * The label is the whole product risk. Derived naively — one label per distinct parenthetical —
 * the real feed yields 596 labels and a single card with SIXTEEN, because World Championship
 * Decks names the deck's AUTHOR ("Torchic - 2004 (Chris Fulop)"). A sixteen-row finish picker is
 * a worse product than no picker at all.
 *
 * So: ONE print run per (card, group). A card carrying several different markers inside the same
 * group is being told apart by provenance, not by print run, and the group is then the honest
 * label. That single rule takes the worst card from 16 labels to 5 and leaves 77% of cards with
 * exactly one — with no hand-maintained vocabulary and no threshold to tune.
 */
export function findPrintRuns(
  groups: { groupId: number; name?: string; products: TcgcsvProduct[] }[],
  mapped: Map<number, string>,
  setByTcgplayerId: Map<number, string>,
  index: Map<string, CardRef[]>,
  setTotals: Map<string, { total: number | null; printedTotal: number | null }>,
): PrintRun[] {
  const cands: { gid: number; cardId: string; productId: number; mark: string | null; base: string }[] = [];
  for (const g of groups) {
    if (mapped.has(g.groupId)) continue;
    for (const p of g.products) {
      const ext = extMap(p);
      if (!("HP" in ext) && !("Card Type" in ext)) continue;
      // Already a SKU of some card: it is priced as that card today and is not ours to relabel.
      if (setByTcgplayerId.has(p.productId)) continue;
      const cardId = resolveCardGlobally(p, index, setTotals);
      if (!cardId) continue;
      const base = printBaseName(p.name, ext["Number"]);
      cands.push({ gid: g.groupId, cardId, productId: p.productId, mark: printMarker(base), base });
    }
  }
  const marksPerCardGroup = new Map<string, Set<string>>();
  for (const c of cands) {
    const k = `${c.cardId}|${c.gid}`;
    const s = marksPerCardGroup.get(k) ?? marksPerCardGroup.set(k, new Set()).get(k)!;
    s.add(c.mark ?? "");
  }
  const groupName = new Map(groups.map((g) => [g.groupId, g.name ?? String(g.groupId)]));
  return cands.map((c) => {
    const name = groupName.get(c.gid)!;
    // The year is part of the print run ("World Championship Decks 2012"), and only the product
    // carries it — the group is one bucket for every year.
    const year = /\b(19|20)\d{2}\b/.exec(c.base)?.[0];
    const fromGroup = year && !/\d{4}/.test(name) ? `${name} ${year}` : name;
    // A year beats the marker outright. "Squirtle - 2006 (Hiroki Yano)" is the only World
    // Championship 2006 Squirtle there is; the parenthetical names the player who built the
    // deck, and "Printing: Hiroki Yano" is not a thing a collector can read off the card.
    const useMark = !year && c.mark && marksPerCardGroup.get(`${c.cardId}|${c.gid}`)!.size === 1;
    return { cardId: c.cardId, groupId: c.gid, productId: c.productId, printing: useMark ? c.mark! : fromGroup };
  });
}

/**
 * Group → set id, voted by the products we already resolve. A set is claimed by at most one
 * group (the one with the most evidence), so an overlapping group can't steal it.
 */
export interface GroupDecision {
  groupId: number;
  products: number;
  matched: number;
  topSet: string | null;
  share: number;
  /** True when `matched` counts name+number votes because no productId resolved. */
  viaFallback?: true;
  /** Why this group produced no cards. `null` when it was accepted. */
  rejected: "no-matches" | "too-few-matches" | "ambiguous" | "lost-to-better-group" | null;
}

export function mapGroupsToSets(
  groups: { groupId: number; products: TcgcsvProduct[] }[],
  setByTcgplayerId: Map<number, string>,
  decisions?: GroupDecision[],
  cardsByNameNumber?: Map<string, CardRef[]>,
): Map<number, string> {
  const best = new Map<string, { groupId: number; matched: number; viaFallback: boolean }>();

  const record = (g: { groupId: number; products: TcgcsvProduct[] }, resolve: (p: TcgcsvProduct) => string | null, viaFallback: boolean) => {
    const votes = new Map<string, number>();
    let matched = 0;
    for (const p of g.products) {
      const setId = resolve(p);
      if (!setId) continue;
      votes.set(setId, (votes.get(setId) ?? 0) + 1);
      matched++;
    }
    let top = "", topN = 0;
    for (const [setId, n] of votes) if (n > topN) { top = setId; topN = n; }
    const share = matched ? topN / matched : 0;
    const d: GroupDecision = {
      groupId: g.groupId, products: g.products.length, matched,
      topSet: top || null, share: Number(share.toFixed(3)),
      ...(viaFallback ? { viaFallback: true as const } : {}),
      rejected: matched === 0 ? "no-matches"
              : matched < MIN_MATCHED_PRODUCTS ? "too-few-matches"
              : share < MIN_DOMINANT_SHARE ? "ambiguous" : null,
    };
    decisions?.push(d);
    if (d.rejected) return;
    const cur = best.get(top);
    // Pass 2 runs after pass 1 in full, so `cur.viaFallback === false` here means the set is
    // already spoken for by real id evidence and a name match must not outbid it.
    if (!cur || (cur.viaFallback === viaFallback && topN > cur.matched)) {
      best.set(top, { groupId: g.groupId, matched: topN, viaFallback });
    }
  };

  // Pass 1 — by productId, the strong key.
  const unresolved: typeof groups = [];
  for (const g of groups) {
    if (cardsByNameNumber && !g.products.some((p) => setByTcgplayerId.has(p.productId))) { unresolved.push(g); continue; }
    record(g, (p) => setByTcgplayerId.get(p.productId) ?? null, false);
  }
  // Pass 2 — name+number, ONLY for groups nothing resolved, and only for sets pass 1 left free.
  for (const g of unresolved) record(g, (p) => resolveByNameNumber(p, cardsByNameNumber!), true);

  const out = new Map<number, string>();
  for (const [setId, { groupId }] of best) out.set(groupId, setId);
  // A group that voted credibly but lost its set to a better-evidenced group.
  if (decisions) for (const d of decisions) if (!d.rejected && !out.has(d.groupId)) d.rejected = "lost-to-better-group";
  return out;
}

export interface SynthesizeInput {
  /** `name` is only used to label a print run whose group no set claimed. */
  groups: { groupId: number; name?: string; products: TcgcsvProduct[] }[];
  /** Every tcgplayer SKU already claimed by a card, → that card's set id. */
  setByTcgplayerId: Map<number, string>;
  /** setId → number keys already present in that set (union of `numberKeys` per card). */
  numbersBySet: Map<string, Set<string>>;
  setTotals: Map<string, { total: number | null; printedTotal: number | null }>;
  /** Lowercased Pokémon name → national dex id, so synthesized cards still reach the Dex. */
  dexByName?: Map<string, number>;
  /** `nameNumberKey` → the cards holding it. Omit to keep the id-only behaviour. */
  cardsByNameNumber?: Map<string, CardRef[]>;
}

export interface SynthesizeResult {
  cards: SynthesizedCard[];
  /** setId → how many cards were added, for the build log. */
  addedBySet: Map<string, number>;
  skippedForeignDenominator: number;
  /** Per-group mapping outcome, for the diagnostic sidecar. */
  decisions: GroupDecision[];
  /** Products dropped for a foreign denominator, with enough to judge the call by eye. */
  rejects: { setId: string; number: string; name: string; productId: number }[];
  /**
   * Existing cards that carry no tcgplayer id and whose product we just identified. The caller
   * appends the productId to that card's `tcgplayerIds` — which is what buys it a price, since
   * every price feed joins on that id and a card without one is silently priceless.
   */
  links: { cardId: string; setId: string; productId: number }[];
  /**
   * Cards we already hold, sold under a print run we do not model — see `findPrintRuns`. Empty
   * unless `cardsByNameNumber` is supplied, like `links`.
   */
  printRuns: PrintRun[];
}

export function synthesizeMissingCards(input: SynthesizeInput): SynthesizeResult {
  const decisions: GroupDecision[] = [];
  const rejects: { setId: string; number: string; name: string; productId: number }[] = [];
  const links: { cardId: string; setId: string; productId: number }[] = [];
  const linked = new Set<string>();
  const groupSets = mapGroupsToSets(input.groups, input.setByTcgplayerId, decisions, input.cardsByNameNumber);
  const cards: SynthesizedCard[] = [];
  const addedBySet = new Map<string, number>();
  let skippedForeignDenominator = 0;

  for (const g of input.groups) {
    const setId = groupSets.get(g.groupId);
    if (!setId) continue;
    const totals = input.setTotals.get(setId) ?? { total: null, printedTotal: null };
    const taken = new Set(input.numbersBySet.get(setId) ?? []);

    for (const p of g.products) {
      const ext = extMap(p);
      // Sealed products carry no card fields; a real card always has HP or a Card Type.
      if (!("HP" in ext) && !("Card Type" in ext)) continue;
      const raw = ext["Number"];
      const keys = numberKeys(raw);
      if (keys.size === 0) continue;
      if (!denominatorFits(raw, totals.total, totals.printedTotal)) {
        skippedForeignDenominator++;
        rejects.push({ setId, number: raw ?? "", name: p.name, productId: p.productId });
        continue;
      }
      if ([...keys].some((k) => taken.has(k))) {
        // Not a hole — a card already holds this number. But it may be one of the cards that has
        // no tcgplayer id, in which case this product is the id it was missing.
        if (input.cardsByNameNumber && !input.setByTcgplayerId.has(p.productId)) {
          const cardId = linkTarget(p, setId, input.cardsByNameNumber, linked);
          if (cardId) { linked.add(cardId); links.push({ cardId, setId, productId: p.productId }); }
        }
        continue;
      }
      for (const k of keys) taken.add(k);

      const localId = (raw ?? "").split("/")[0].trim();
      const name = cleanName(p.name, localId);
      const attacks = ["Attack 1", "Attack 2", "Attack 3", "Attack 4"]
        .map((k) => (ext[k] ? parseAttack(ext[k]) : null))
        .filter((a): a is NonNullable<typeof a> => !!a);
      const hp = /^\d+$/.test(ext["HP"] ?? "") ? Number(ext["HP"]) : null;
      const cardType = (ext["Card Type"] ?? "").trim();
      const dexId = input.dexByName?.get(name.toLowerCase());

      cards.push({
        id: `${setId}-${localId}`,
        setId,
        serieId: null,       // no tcgdex art — the app falls back to the TCGplayer CDN via tcgplayer_id
        localId,
        name,
        hp,
        types: hp != null && CARD_TYPES.has(cardType) ? [cardType] : [],
        rarity: ext["Rarity"] || null,
        artist: null,        // not in the tcgcsv feed
        text: [stripHtml(ext["CardText"] ?? ""), ...attacks.map((a) => a.effect)].filter(Boolean).join("\n"),
        attacks: attacks.map((a) => ({ name: a.name, damage: a.damage, cost: a.cost, ...(a.effect ? { effect: a.effect } : {}) })),
        // These are the cards TCGdex does not have — so they have no TCGdex art either, which makes
        // them exactly the cards most likely to be read off the offline fact sheet. The feed carries
        // less than TCGdex does; every key is omitted rather than guessed.
        detail: pickCsvDetail(ext, hp),
        tcgplayerIds: [p.productId],
        tcgplayerByType: [],
        cardmarketIds: [],
        dexId: dexId != null ? [dexId] : [],
      });
      addedBySet.set(setId, (addedBySet.get(setId) ?? 0) + 1);
    }
  }
  const printRuns = input.cardsByNameNumber
    ? findPrintRuns(input.groups, groupSets, input.setByTcgplayerId, input.cardsByNameNumber, input.setTotals)
    : [];
  return { cards, addedBySet, skippedForeignDenominator, decisions, rejects, links, printRuns };
}

/**
 * "Chikorita - 046" → "Chikorita". Only the number suffix is stripped: a parenthetical like
 * "(Pitch Black Stamped)" is how the print is actually distinguished, so it stays in the name.
 */
export function cleanName(productName: string, localId: string): string {
  if (!localId) return productName.trim();
  // TCGplayer writes the suffix as either the full localId ("- SWSH300") or its numeric tail
  // ("Jirachi V - 299" for SWSH299), so try both.
  const forms = [localId, /(\d+)$/.exec(localId)?.[1]].filter((s): s is string => !!s);
  let out = productName;
  for (const form of forms) {
    const esc = form.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const next = out.replace(new RegExp(`\\s+-\\s+0*${esc}(?![\\w/])`, "i"), "");
    if (next !== out) { out = next; break; }
  }
  return out.replace(/\s+/g, " ").trim();
}
