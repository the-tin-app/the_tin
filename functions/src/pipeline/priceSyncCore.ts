import { gzipSync } from "node:zlib";
import { PptClient, CreditBudgetExceeded, PptPrice } from "../upstream/ppt";
import { matchPrices } from "./matcher";
import type { StoragePort } from "./publish";
import { TcgdexClient, TcgdexCard } from "../upstream/tcgdex";

export function setIdOf(cardId: string): string {
  return cardId.slice(0, cardId.lastIndexOf("-"));
}

/**
 * Derives the set of priority set ids from raw entry cardId values and wants
 * doc ids. Entry cardIds come from arbitrary user-written documents and may
 * be missing or non-string; those are skipped rather than throwing. Wants
 * doc ids are Firestore document ids (always strings) and are used as-is;
 * any junk ids are filtered downstream by setOrder membership.
 */
export function prioritySetIdsFrom(entryCardIds: unknown[], wantDocIds: string[]): string[] {
  const setIds = new Set<string>();
  for (const cid of entryCardIds) {
    if (typeof cid === "string" && cid.includes("-")) setIds.add(setIdOf(cid));
  }
  for (const id of wantDocIds) setIds.add(setIdOf(id));
  return [...setIds];
}

export interface CatalogCardRef { id: string; setId: string; setName: string; localId: string; name: string }
export interface PriceRow {
  cardId: string; rawUsd: number | null; rawEur: number | null;
  psa3: number | null; psa7: number | null; psa9: number | null; psa10: number | null;
}
export interface FirestorePort {
  getCursor(): Promise<number>;
  setCursor(n: number): Promise<void>;
  getPrioritySetIds(): Promise<string[]>;
  writeSnapshots(rows: PriceRow[], date: string): Promise<void>;
}

export async function runPriceSync(opts: {
  cards: CatalogCardRef[]; setOrder: string[]; ppt: PptClient; tcgdex: TcgdexClient; gradedActive: boolean;
  store: FirestorePort; storage: StoragePort; date: string;
  // Bounds the number of ROTATION sets fetched per run (priority sets are always
  // synced on top). Each rotation set is a live TCGdex getSetCards (1+N requests),
  // so without a cap a daily run would sweep the whole catalog (~23k requests).
  // The cursor advances so successive runs cover the full rotation over time.
  maxRotationSetsPerRun?: number;
}): Promise<{ syncedSets: string[]; rows: PriceRow[] }> {
  const { cards, setOrder, ppt, tcgdex, gradedActive, store, storage, date, maxRotationSetsPerRun } = opts;
  const priority = await store.getPrioritySetIds();
  const cursor = await store.getCursor();
  const rotationAll = [...setOrder.slice(cursor), ...setOrder.slice(0, cursor)].filter(s => !priority.includes(s));
  const rotation = maxRotationSetsPerRun != null ? rotationAll.slice(0, maxRotationSetsPerRun) : rotationAll;
  const queue = [...priority.filter(s => setOrder.includes(s)), ...rotation];

  const bySet = new Map<string, CatalogCardRef[]>();
  for (const c of cards) (bySet.get(c.setId) ?? bySet.set(c.setId, []).get(c.setId)!).push(c);

  const rows: PriceRow[] = [];
  const syncedSets: string[] = [];
  for (const setId of queue) {
    const refs = bySet.get(setId) ?? [];
    if (refs.length === 0) continue;
    try {
      const tcgCards = await tcgdex.getSetCards(setId);        // raw_usd/raw_eur
      const rawById = new Map(tcgCards.map((c) => [c.id, c]));
      const graded = new Map<string, PptPrice>();
      if (gradedActive) {
        const prices = await ppt.getSetPrices(refs[0].setName, { graded: true });
        const asCards: TcgdexCard[] = refs.map((r) => ({
          id: r.id, localId: r.localId, name: r.name, hp: null, types: [], rarity: null, artist: null,
          text: "", imageBase: null, rawUsd: null, rawEur: null,
        }));
        for (const [cardId, p] of matchPrices(asCards, prices)) graded.set(cardId, p);
      }
      for (const ref of refs) {
        const tc = rawById.get(ref.id);
        const g = graded.get(ref.id);
        const rawUsd = tc?.rawUsd ?? null, rawEur = tc?.rawEur ?? null;
        if (rawUsd == null && rawEur == null && !g) continue;   // coverage rule
        rows.push({
          cardId: ref.id, rawUsd, rawEur,
          psa3: g?.graded.psa3 ?? null, psa7: g?.graded.psa7 ?? null,
          psa9: g?.graded.psa9 ?? null, psa10: g?.graded.psa10 ?? null,
        });
      }
      syncedSets.push(setId);
    } catch (e) {
      if (e instanceof CreditBudgetExceeded) break;
      console.warn(`priceSync: set ${setId} failed: ${e}`);
    }
  }

  await store.setCursor((cursor + syncedSets.length) % Math.max(setOrder.length, 1));
  await store.writeSnapshots(rows, date);
  await storage.save(`catalog/deltas/prices-${date}.json.gz`, gzipSync(JSON.stringify({ asOf: date, rows })), "application/gzip");
  return { syncedSets, rows };
}
