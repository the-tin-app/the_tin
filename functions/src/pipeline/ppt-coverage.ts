import { matchPptToOurCards, type OurCardRef } from "./matcher";
import type { PptCard } from "../upstream/ppt";

export interface OurCard {
  id: string;
  localId: string;
  name: string;
  hasImage: boolean;
  hasPrice: boolean;
  tcgplayerId?: number | null;
}

export interface SetCoverage {
  matched: number;
  imageFillable: number;
  priceFillable: number;
}

const toRef = (c: OurCard): OurCardRef =>
  ({ id: c.id, number: c.localId, name: c.name, tcgplayerId: c.tcgplayerId });

/**
 * How much of a set PPT could fill, counted with the SAME matcher `computeFills` uses.
 *
 * It has to be the same one or the probe lies about the thing it exists to predict. The old
 * bare-number short-circuit here counted a card matched whenever one PPT product shared its
 * number, names unchecked, and counted one product against several of our cards when their
 * numbers normalized alike — so coverage read higher than the fill would ever deliver.
 */
export function computeCoverage(ourCards: OurCard[], pptCards: PptCard[]): SetCoverage {
  const byId = new Map(ourCards.map((c) => [c.id, c]));
  let matched = 0, imageFillable = 0, priceFillable = 0;
  for (const [p, ref] of matchPptToOurCards(ourCards.map(toRef), pptCards)) {
    const c = byId.get(ref.id)!;
    matched++;
    if (!c.hasImage && p.imageUrl != null) imageFillable++;
    if (!c.hasPrice && p.marketUsd != null) priceFillable++;
  }
  return { matched, imageFillable, priceFillable };
}
