export type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;

export interface TcgdexSet {
  id: string; name: string; releaseDate: string | null;
  cardCountTotal: number; printedTotal: number | null; serie: string | null;
}
export interface TcgdexAttack { name: string; damage: string | null; cost: string[]; effect?: string }
export interface TcgdexAbility { name: string; type?: string; effect?: string }
export interface TcgdexTypeValue { type: string; value: string }

/**
 * Everything else the card prints, for the offline fact sheet (`CardFactSheet` on iOS).
 * Stored as ONE JSON column so a field added later never costs another schema migration.
 */
export interface TcgdexDetail {
  category?: string;
  stage?: string;
  evolveFrom?: string;
  abilities?: TcgdexAbility[];
  weaknesses?: TcgdexTypeValue[];
  resistances?: TcgdexTypeValue[];
  retreat?: number;
  regulationMark?: string;
  trainerType?: string;
  effect?: string;
}

export interface TcgdexCard {
  id: string; localId: string; name: string; hp: number | null;
  types: string[]; rarity: string | null; artist: string | null;
  text: string; imageBase: string | null;
  imageUrl?: string | null;
  rawUsd: number | null; rawEur: number | null;
  attacks?: TcgdexAttack[];
  detail?: TcgdexDetail;
}

/**
 * Attack list for the no-image fact sheet: name, damage, energy cost and effect text.
 *
 * ⚠️ `damage` arrives as a NUMBER for plain damage (90) and a STRING when it is printed with a
 * modifier ("90+", "20×"). Both occur on the live API; always stringify.
 */
export function pickAttacks(raw: { attacks?: { name?: unknown; damage?: unknown; cost?: unknown; effect?: unknown }[] }): TcgdexAttack[] {
  return (raw.attacks ?? []).flatMap((a) => {
    if (typeof a?.name !== "string" || !a.name) return [];
    return [{
      name: a.name,
      damage: a.damage != null ? String(a.damage) : null,
      cost: Array.isArray(a.cost) ? a.cost.filter((c): c is string => typeof c === "string") : [],
      ...(typeof a.effect === "string" && a.effect ? { effect: a.effect } : {}),
    }];
  });
}

const str = (v: unknown): string | undefined => (typeof v === "string" && v ? v : undefined);

function pickTypeValues(raw: unknown): TcgdexTypeValue[] | undefined {
  if (!Array.isArray(raw)) return undefined;
  const out = raw.flatMap((w: any) => {
    const type = str(w?.type), value = w?.value != null ? String(w.value) : undefined;
    return type && value ? [{ type, value }] : [];
  });
  return out.length ? out : undefined;
}

/**
 * The rest of the printed card. Costs NOTHING upstream — `getSetCards` already fetches the full
 * `/cards/{id}` record per card and `buildCardText` already parses abilities and attack effects,
 * then flattens them into an FTS blob and discards the structure. This keeps the structure.
 *
 * Every key is omitted when absent rather than emitted as null: `JSON.stringify` drops undefined,
 * and the Swift side declares each field a real `Optional` for exactly that reason.
 */
export function pickDetail(raw: any): TcgdexDetail | undefined {
  const abilities = Array.isArray(raw?.abilities)
    ? raw.abilities.flatMap((a: any) => {
        const name = str(a?.name);
        return name ? [{ name, ...(str(a?.type) ? { type: str(a.type)! } : {}), ...(str(a?.effect) ? { effect: str(a.effect)! } : {}) }] : [];
      })
    : [];
  const detail: TcgdexDetail = {
    ...(str(raw?.category) ? { category: str(raw.category)! } : {}),
    ...(str(raw?.stage) ? { stage: str(raw.stage)! } : {}),
    ...(str(raw?.evolveFrom) ? { evolveFrom: str(raw.evolveFrom)! } : {}),
    ...(abilities.length ? { abilities } : {}),
    ...(pickTypeValues(raw?.weaknesses) ? { weaknesses: pickTypeValues(raw.weaknesses)! } : {}),
    ...(pickTypeValues(raw?.resistances) ? { resistances: pickTypeValues(raw.resistances)! } : {}),
    ...(typeof raw?.retreat === "number" ? { retreat: raw.retreat } : {}),
    ...(str(raw?.regulationMark) ? { regulationMark: str(raw.regulationMark)! } : {}),
    ...(str(raw?.trainerType) ? { trainerType: str(raw.trainerType)! } : {}),
    ...(str(raw?.effect) ? { effect: str(raw.effect)! } : {}),
  };
  return Object.keys(detail).length ? detail : undefined;
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
        attacks: pickAttacks(c),
        detail: pickDetail(c),
        imageBase: c.image ?? null,
        rawUsd: pickTcgplayerMarket(c.pricing?.tcgplayer),
        rawEur: typeof c.pricing?.cardmarket?.trend === "number" ? c.pricing.cardmarket.trend : null,
      });
    }
    return out;
  }
}
