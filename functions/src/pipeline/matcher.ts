import type { TcgdexCard } from "../upstream/tcgdex";
import type { PptPrice } from "../upstream/ppt";

export function normalizeNumber(n: string): string {
  const head = n.split("/")[0].trim().toUpperCase();
  return head.replace(/^0+(?=\w)/, "");
}

function normalizeName(n: string): string {
  return n.toLowerCase().replace(/[^a-z0-9]/g, "");
}

export function matchPrices(cards: TcgdexCard[], prices: PptPrice[]): Map<string, PptPrice> {
  const byNumber = new Map<string, PptPrice[]>();
  for (const p of prices) {
    const k = normalizeNumber(p.cardNumber);
    (byNumber.get(k) ?? byNumber.set(k, []).get(k)!).push(p);
  }
  const out = new Map<string, PptPrice>();
  for (const c of cards) {
    const candidates = byNumber.get(normalizeNumber(c.localId)) ?? [];
    if (candidates.length === 1) { out.set(c.id, candidates[0]); continue; }
    const byName = candidates.find((p) => normalizeName(p.name) === normalizeName(c.name));
    if (byName) out.set(c.id, byName);
  }
  return out;
}

export interface OurCardRef { id: string; number: string; name: string; tcgplayerId?: number | null }
export interface PptCardRef { cardNumber: string; name: string; tcgPlayerId?: number | null }

/** TCGplayer suffixes a stamped print run onto the base product's name — `Alolan Raichu - SM72
 *  (Prerelease)` vs `... (Prerelease) [Staff]`, and eight `[Champion]`/`[Finalist]`/… variants of
 *  one Champions Festival. Our catalog models only the unstamped base card, so among products
 *  contesting a number the unstamped one is ours. */
const STAMPED = /\[[^\]]+\]\s*$/;

/** PPT names a card `"<Name> - <Number> (<Print run>)"`, so the head before the first " - " is
 *  the plain card name. Only safe once an id has already narrowed the field to one product — on
 *  its own it matches every stamped sibling equally. */
function pptBaseName(n: string): string {
  return n.split(" - ")[0];
}

/** Two ids that both exist and disagree are two different TCGplayer products, so a bare number
 *  must not promote the pair. An exact NAME match still outranks this (see step 2) — our id is
 *  only a card's first sku. Either side missing an id proves nothing. */
function compatible(c: OurCardRef, p: PptCardRef): boolean {
  return c.tcgplayerId == null || p.tcgPlayerId == null || String(c.tcgplayerId) === String(p.tcgPlayerId);
}

/**
 * Resolve a PPT set's cards onto ours, **one-to-one in both directions**.
 *
 * A PPT set routinely carries more products than our set has cards: Staff/Prerelease stampings
 * repeat a number, promo sets fold several print runs together, and PPT models both halves of a
 * trainer kit as one set numbered 1-30 twice. `normalizeNumber` also drops the denominator, so
 * `32/97` and `032` collide. Matching on number alone therefore lets SEVERAL PPT products claim
 * ONE of our cards, and every caller here writes per PPT card — so they all landed, interleaved,
 * on the same `card_id`. `np-32` Articuno ex carried a Gyarados Prerelease's price series and a
 * $262.50 "Normal" printing it does not have.
 *
 * Resolution order:
 *   1. `tcgPlayerId` — an exact product identity, so it outranks everything else. An id several of
 *      our cards share is settled by PPT's own name, never by index order;
 *   2. among cards step 1 left unclaimed: an exact name match, else the number — but a number
 *      contested by several PPT products only promotes the one unstamped base card, and a number
 *      whose candidate carries a disagreeing id never promotes at all. Nothing wins an unbroken tie.
 *
 * Unmatched is a deliberate outcome, not a failure: a card PPT can only identify by a contested
 * number keeps yesterday's value instead of a coin flip between a $11.14 card and a $100 one.
 */
export function matchPptToOurCards<P extends PptCardRef>(our: OurCardRef[], ppt: P[]): Map<P, OurCardRef> {
  const out = new Map<P, OurCardRef>();
  const claimed = new Set<string>();

  // `card.tcgplayer_id` holds only the card's FIRST SKU, and two cards in a set can end up
  // stamped with the same one — np-16 Treecko and np-17 Torchic both carry 153317, which really
  // belongs to Torchic. An id claimed by several of our cards can't identify one on its own, so
  // PPT's own name breaks the tie; taking whichever was indexed last would be a coin flip.
  const byTcg = new Map<string, OurCardRef[]>();
  for (const c of our) {
    if (c.tcgplayerId == null) continue;
    const k = String(c.tcgplayerId);
    (byTcg.get(k) ?? byTcg.set(k, []).get(k)!).push(c);
  }

  const rest: P[] = [];
  for (const p of ppt) {
    const sharing = (p.tcgPlayerId != null ? byTcg.get(String(p.tcgPlayerId)) : undefined) ?? [];
    const hit = sharing.length === 1 ? sharing[0]
      : sharing.filter((c) => normalizeName(c.name) === normalizeName(pptBaseName(p.name)))[0];
    if (hit && !claimed.has(hit.id)) { out.set(p, hit); claimed.add(hit.id); }
    else rest.push(p);
  }

  const ourByNum = new Map<string, OurCardRef[]>();
  for (const c of our) {
    const k = normalizeNumber(c.number);
    (ourByNum.get(k) ?? ourByNum.set(k, []).get(k)!).push(c);
  }
  const restByNum = new Map<string, P[]>();
  for (const p of rest) {
    const k = normalizeNumber(p.cardNumber);
    (restByNum.get(k) ?? restByNum.set(k, []).get(k)!).push(p);
  }

  for (const [k, group] of restByNum) {
    // `smp` carries a tcgplayer_id on 4 of its 248 cards, so ids cannot referee there and PPT's
    // names never equal ours. The stamp convention can: exactly one contender is unstamped.
    const unstamped = group.filter((p) => !STAMPED.test(p.name));
    for (const p of group) {
      const free = (ourByNum.get(k) ?? []).filter((c) => !claimed.has(c.id));
      // The id test gates promotion on a bare NUMBER, which is the weak signal that let a
      // Gyarados into Articuno ex. It must not veto an exact name match: `card.tcgplayer_id` is
      // only the first of a card's SKUs, so PPT legitimately reports a different one for the same
      // card (me02.5-155 N's Zekrom, ours 704446 against PPT's 675967).
      const named = free.find((c) => normalizeName(c.name) === normalizeName(p.name));
      const usable = free.filter((c) => compatible(c, p));
      const sole = group.length === 1 || (unstamped.length === 1 && unstamped[0] === p);
      const m = named ?? (sole && usable.length === 1 ? usable[0] : null);
      if (m) { out.set(p, m); claimed.add(m.id); }
    }
  }
  return out;
}
