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
