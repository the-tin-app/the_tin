import { matchPptToOurCards, type OurCardRef } from "./matcher";
import type { PptCard } from "../upstream/ppt";

export interface Fill { imageUrl: string | null; rawUsd: number | null; }
export interface OurCard {
  id: string; localId: string; name: string; hasImage: boolean; hasPrice: boolean;
  tcgplayerId?: number | null;
}

const toRef = (c: OurCard): OurCardRef =>
  ({ id: c.id, number: c.localId, name: c.name, tcgplayerId: c.tcgplayerId });

/**
 * Which PPT product fills each of our image-gap cards.
 *
 * Resolution is `matchPptToOurCards`, the same one-to-one matcher the price sweeps use (#185).
 * This used to key PPT by number and take `cands[0]` whenever exactly one product carried our
 * card's number — a bare-number match with the name check SKIPPED, and no claim tracking. Two
 * ways that wrote wrong data, both worst in exactly the sets this function is for (promos,
 * trainer kits — `normalizeNumber` drops the denominator, so `32/97` and `032` collide):
 *   - one PPT product filled EVERY card of ours whose number normalized the same, copying one
 *     image and one price across several different cards;
 *   - a lone same-numbered product was taken on the number alone, so a disagreeing
 *     `tcgPlayerId` could not veto it.
 * It also lost legitimate fills: `Alolan Raichu - SM72 (Prerelease)` never equals `Alolan
 * Raichu`, so a stamped-variant group fell through the name check to nothing. The matcher's
 * unstamped-base rule recovers those.
 */
export function computeFills(ourCards: OurCard[], pptCards: PptCard[]): Map<string, Fill> {
  const byId = new Map(ourCards.map((c) => [c.id, c]));
  const out = new Map<string, Fill>();
  for (const [p, ref] of matchPptToOurCards(ourCards.map(toRef), pptCards)) {
    const c = byId.get(ref.id)!;
    const imageUrl = !c.hasImage && p.imageUrl != null ? p.imageUrl : null;
    const rawUsd = !c.hasPrice && p.marketUsd != null ? p.marketUsd : null;
    if (imageUrl != null || rawUsd != null) out.set(c.id, { imageUrl, rawUsd });
  }
  return out;
}
