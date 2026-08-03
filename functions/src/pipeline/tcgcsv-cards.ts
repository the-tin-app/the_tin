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
 */
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
  attacks: { name: string; damage: string | null; cost: string[] }[];
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

function stripHtml(s: string): string {
  return s.replace(/<[^>]+>/g, " ").replace(/&amp;/g, "&").replace(/&#39;|&rsquo;/g, "'")
    .replace(/&quot;/g, '"').replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim();
}

/**
 * Group → set id, voted by the products we already resolve. A set is claimed by at most one
 * group (the one with the most evidence), so an overlapping group can't steal it.
 */
export function mapGroupsToSets(
  groups: { groupId: number; products: TcgcsvProduct[] }[],
  setByTcgplayerId: Map<number, string>,
): Map<number, string> {
  const best = new Map<string, { groupId: number; matched: number }>();
  for (const g of groups) {
    const votes = new Map<string, number>();
    let matched = 0;
    for (const p of g.products) {
      const setId = setByTcgplayerId.get(p.productId);
      if (!setId) continue;
      votes.set(setId, (votes.get(setId) ?? 0) + 1);
      matched++;
    }
    if (matched < MIN_MATCHED_PRODUCTS) continue;
    let top = "", topN = 0;
    for (const [setId, n] of votes) if (n > topN) { top = setId; topN = n; }
    if (topN / matched < MIN_DOMINANT_SHARE) continue;
    const cur = best.get(top);
    if (!cur || topN > cur.matched) best.set(top, { groupId: g.groupId, matched: topN });
  }
  const out = new Map<number, string>();
  for (const [setId, { groupId }] of best) out.set(groupId, setId);
  return out;
}

export interface SynthesizeInput {
  groups: { groupId: number; products: TcgcsvProduct[] }[];
  /** Every tcgplayer SKU already claimed by a card, → that card's set id. */
  setByTcgplayerId: Map<number, string>;
  /** setId → number keys already present in that set (union of `numberKeys` per card). */
  numbersBySet: Map<string, Set<string>>;
  setTotals: Map<string, { total: number | null; printedTotal: number | null }>;
  /** Lowercased Pokémon name → national dex id, so synthesized cards still reach the Dex. */
  dexByName?: Map<string, number>;
}

export interface SynthesizeResult {
  cards: SynthesizedCard[];
  /** setId → how many cards were added, for the build log. */
  addedBySet: Map<string, number>;
  skippedForeignDenominator: number;
}

export function synthesizeMissingCards(input: SynthesizeInput): SynthesizeResult {
  const groupSets = mapGroupsToSets(input.groups, input.setByTcgplayerId);
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
      if (!denominatorFits(raw, totals.total, totals.printedTotal)) { skippedForeignDenominator++; continue; }
      if ([...keys].some((k) => taken.has(k))) continue;
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
        attacks: attacks.map((a) => ({ name: a.name, damage: a.damage, cost: a.cost })),
        tcgplayerIds: [p.productId],
        tcgplayerByType: [],
        cardmarketIds: [],
        dexId: dexId != null ? [dexId] : [],
      });
      addedBySet.set(setId, (addedBySet.get(setId) ?? 0) + 1);
    }
  }
  return { cards, addedBySet, skippedForeignDenominator };
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
