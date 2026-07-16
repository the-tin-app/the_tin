import { normalizeNumber } from "./matcher";
import type { PptCard } from "../upstream/ppt";

export interface Fill { imageUrl: string | null; rawUsd: number | null; }
export interface OurCard { id: string; localId: string; name: string; hasImage: boolean; hasPrice: boolean; }

function normalizeName(n: string): string { return n.toLowerCase().replace(/[^a-z0-9]/g, ""); }

export function computeFills(ourCards: OurCard[], pptCards: PptCard[]): Map<string, Fill> {
  const byNumber = new Map<string, PptCard[]>();
  for (const p of pptCards) {
    const k = normalizeNumber(p.cardNumber);
    (byNumber.get(k) ?? byNumber.set(k, []).get(k)!).push(p);
  }
  const out = new Map<string, Fill>();
  for (const c of ourCards) {
    const cands = byNumber.get(normalizeNumber(c.localId)) ?? [];
    const hit = cands.length === 1 ? cands[0]
      : cands.find((p) => normalizeName(p.name) === normalizeName(c.name)) ?? null;
    if (!hit) continue;
    const imageUrl = !c.hasImage && hit.imageUrl != null ? hit.imageUrl : null;
    const rawUsd = !c.hasPrice && hit.marketUsd != null ? hit.marketUsd : null;
    if (imageUrl != null || rawUsd != null) out.set(c.id, { imageUrl, rawUsd });
  }
  return out;
}
