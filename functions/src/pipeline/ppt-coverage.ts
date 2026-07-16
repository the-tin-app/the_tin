import { normalizeNumber } from "./matcher";
import type { PptCard } from "../upstream/ppt";

export interface OurCard {
  id: string;
  localId: string;
  name: string;
  hasImage: boolean;
  hasPrice: boolean;
}

export interface SetCoverage {
  matched: number;
  imageFillable: number;
  priceFillable: number;
}

function normalizeName(n: string): string {
  return n.toLowerCase().replace(/[^a-z0-9]/g, "");
}

export function computeCoverage(ourCards: OurCard[], pptCards: PptCard[]): SetCoverage {
  const byNumber = new Map<string, PptCard[]>();
  for (const p of pptCards) {
    const k = normalizeNumber(p.cardNumber);
    (byNumber.get(k) ?? byNumber.set(k, []).get(k)!).push(p);
  }
  let matched = 0, imageFillable = 0, priceFillable = 0;
  for (const c of ourCards) {
    const cands = byNumber.get(normalizeNumber(c.localId)) ?? [];
    const hit = cands.length === 1 ? cands[0]
      : cands.find((p) => normalizeName(p.name) === normalizeName(c.name)) ?? null;
    if (!hit) continue;
    matched++;
    if (!c.hasImage && hit.imageUrl != null) imageFillable++;
    if (!c.hasPrice && hit.marketUsd != null) priceFillable++;
  }
  return { matched, imageFillable, priceFillable };
}
