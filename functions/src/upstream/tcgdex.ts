export type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;

export interface TcgdexSet {
  id: string; name: string; releaseDate: string | null;
  cardCountTotal: number; printedTotal: number | null; serie: string | null;
}
export interface TcgdexCard {
  id: string; localId: string; name: string; hp: number | null;
  types: string[]; rarity: string | null; artist: string | null;
  text: string; imageBase: string | null;
  imageUrl?: string | null;
  rawUsd: number | null; rawEur: number | null;
}

const BASE = "https://api.tcgdex.net/v2/en";

const TCGPLAYER_VARIANT_ORDER = ["normal", "holofoil", "reverse"];

export function pickTcgplayerMarket(tcgplayer: any): number | null {
  if (!tcgplayer || typeof tcgplayer !== "object") return null;
  const variantKeys = Object.keys(tcgplayer).filter((k) => tcgplayer[k] && typeof tcgplayer[k] === "object" && "marketPrice" in tcgplayer[k]);
  const ordered = [...TCGPLAYER_VARIANT_ORDER.filter((k) => variantKeys.includes(k)),
                   ...variantKeys.filter((k) => !TCGPLAYER_VARIANT_ORDER.includes(k))];
  for (const k of ordered) {
    const m = tcgplayer[k]?.marketPrice;
    if (typeof m === "number") return m;
  }
  return null;
}

export function buildCardText(raw: {
  abilities?: { name?: string; effect?: string }[];
  attacks?: { name?: string; effect?: string }[];
}): string {
  const parts: string[] = [];
  for (const a of raw.abilities ?? []) { if (a.name) parts.push(a.name); if (a.effect) parts.push(a.effect); }
  for (const a of raw.attacks ?? [])   { if (a.name) parts.push(a.name); if (a.effect) parts.push(a.effect); }
  return parts.join("\n");
}

export class TcgdexClient {
  constructor(private fetchFn: FetchFn = fetch) {}

  private async getJson(path: string): Promise<any> {
    const res = await this.fetchFn(`${BASE}${path}`);
    if (!res.ok) throw new Error(`TCGdex ${res.status} for ${path}`);
    return res.json();
  }

  async listSets(): Promise<TcgdexSet[]> {
    const raw = await this.getJson("/sets");
    return (raw as any[]).map((s) => ({
      id: s.id,
      name: s.name,
      releaseDate: s.releaseDate ?? null,
      cardCountTotal: s.cardCount?.total ?? 0,
      printedTotal: typeof s.cardCount?.official === "number" ? s.cardCount.official : null,
      serie: s.serie?.name ?? null,
    }));
  }

  async getSetCards(setId: string): Promise<TcgdexCard[]> {
    const set = await this.getJson(`/sets/${setId}`);
    const briefs: any[] = set.cards ?? [];
    const out: TcgdexCard[] = [];
    for (const b of briefs) {
      const c = await this.getJson(`/cards/${b.id}`);
      out.push({
        id: c.id,
        localId: String(c.localId),
        name: c.name,
        hp: typeof c.hp === "number" ? c.hp : null,
        types: c.types ?? [],
        rarity: c.rarity ?? null,
        artist: c.illustrator ?? null,
        text: buildCardText(c),
        imageBase: c.image ?? null,
        rawUsd: pickTcgplayerMarket(c.pricing?.tcgplayer),
        rawEur: typeof c.pricing?.cardmarket?.trend === "number" ? c.pricing.cardmarket.trend : null,
      });
    }
    return out;
  }
}
