import { describe, it, expect } from "vitest";
import { gunzipSync } from "node:zlib";
import { runPriceSync, FirestorePort, PriceRow, CatalogCardRef, prioritySetIdsFrom } from "../src/pipeline/priceSyncCore";
import { PptClient, CreditBudget } from "../src/upstream/ppt";
import type { TcgdexClient, TcgdexCard } from "../src/upstream/tcgdex";
import type { StoragePort } from "../src/pipeline/publish";

const cards: CatalogCardRef[] = [
  { id: "swsh7-215", setId: "swsh7", setName: "Evolving Skies", localId: "215", name: "Rayquaza VMAX" },
  { id: "sv1-1", setId: "sv1", setName: "Scarlet & Violet", localId: "1", name: "Sprigatito" },
  { id: "sv2-1", setId: "sv2", setName: "Paldea Evolved", localId: "1", name: "Pikachu" }
];

const pptFetch = async (url: string) => {
  const u = new URL(url);
  const set = u.searchParams.get("set")!;
  const bySet: Record<string, unknown[]> = {
    "Evolving Skies": [{
      tcgPlayerId: 1, name: "Rayquaza VMAX", setName: set, cardNumber: "215", prices: { market: 92.5 },
      ebay: { salesByGrade: { psa9: { medianPrice: 150 }, psa10: { medianPrice: 300 } } },
    }],
    "Scarlet & Violet": [{ tcgPlayerId: 2, name: "Sprigatito", setName: set, cardNumber: "1", prices: { market: 0.2 } }],
    "Paldea Evolved": [{ tcgPlayerId: 3, name: "Pikachu", setName: set, cardNumber: "1", prices: { market: 0.4 } }]
  };
  return new Response(JSON.stringify({ data: bySet[set] ?? [] }), { status: 200 });
};

const tcgdexBySet: Record<string, TcgdexCard[]> = {
  swsh7: [{
    id: "swsh7-215", localId: "215", name: "Rayquaza VMAX", hp: null, types: [], rarity: null, artist: null,
    text: "", imageBase: null, rawUsd: 92.5, rawEur: 80.1,
  }],
  sv1: [{
    id: "sv1-1", localId: "1", name: "Sprigatito", hp: null, types: [], rarity: null, artist: null,
    text: "", imageBase: null, rawUsd: 0.2, rawEur: 0.15,
  }],
  sv2: [{
    id: "sv2-1", localId: "1", name: "Pikachu", hp: null, types: [], rarity: null, artist: null,
    text: "", imageBase: null, rawUsd: 0.4, rawEur: 0.3,
  }],
};

// Fake tcgdex test double: TcgdexClient carries a private fetchFn, so a real
// instance can't be duck-typed; a cast keeps this a lightweight fake per the
// brief instead of standing up a full fetch mock for the two-step API.
const fakeTcgdex = {
  getSetCards: async (setId: string) => tcgdexBySet[setId] ?? [],
} as unknown as TcgdexClient;

class MemStore implements FirestorePort {
  cursor = 0; snapshots: { rows: PriceRow[]; date: string }[] = [];
  constructor(private priority: string[]) {}
  async getCursor() { return this.cursor; }
  async setCursor(n: number) { this.cursor = n; }
  async getPrioritySetIds() { return this.priority; }
  async writeSnapshots(rows: PriceRow[], date: string) { this.snapshots.push({ rows, date }); }
}
class MemStorage implements StoragePort {
  files = new Map<string, Buffer>();
  async save(path: string, data: Buffer) { this.files.set(path, data); }
}

describe("runPriceSync", () => {
  it("syncs priority sets first, then rotation; writes snapshots and gzipped delta", async () => {
    const store = new MemStore(["sv2"]);
    const storage = new MemStorage();
    const ppt = new PptClient("K", new CreditBudget(1000), pptFetch);
    const { syncedSets, rows } = await runPriceSync({
      cards, setOrder: ["swsh7", "sv1", "sv2"], ppt, tcgdex: fakeTcgdex, gradedActive: true, store, storage, date: "2026-07-04"
    });
    expect(syncedSets[0]).toBe("sv2"); // priority first
    expect(syncedSets).toEqual(expect.arrayContaining(["swsh7", "sv1", "sv2"]));
    const rayquaza = rows.find(r => r.cardId === "swsh7-215");
    expect(rayquaza?.rawUsd).toBe(92.5);
    expect(rayquaza?.rawEur).toBe(80.1);
    expect(rayquaza?.psa9).toBe(150);
    expect(rayquaza?.psa10).toBe(300);
    const delta = JSON.parse(gunzipSync(storage.files.get("catalog/deltas/prices-2026-07-04.json.gz")!).toString());
    expect(delta.asOf).toBe("2026-07-04");
    expect(delta.rows).toHaveLength(3);
    expect(store.snapshots).toHaveLength(1);
  });

  it("stops at PPT budget exhaustion (graded active) but still writes what it has, advancing the cursor", async () => {
    const store = new MemStore([]);
    const storage = new MemStorage();
    const ppt = new PptClient("K", new CreditBudget(2), pptFetch); // enough for ~1 card at 2 credits/card (graded)
    const { syncedSets } = await runPriceSync({
      cards, setOrder: ["swsh7", "sv1", "sv2"], ppt, tcgdex: fakeTcgdex, gradedActive: true, store, storage, date: "2026-07-05"
    });
    expect(syncedSets.length).toBeGreaterThanOrEqual(1);
    expect(syncedSets.length).toBeLessThan(3);
    expect(storage.files.has("catalog/deltas/prices-2026-07-05.json.gz")).toBe(true);
    expect(store.cursor).toBe(syncedSets.length); // resumes where it stopped
  });

  it("when gradedActive is false, never calls PPT and emits raw-only rows with null psa*", async () => {
    const store = new MemStore(["sv2"]);
    const storage = new MemStorage();
    const throwingPpt = {
      getSetPrices: () => { throw new Error("PPT must not be called when gradedActive is false"); },
    } as unknown as PptClient;
    const { rows } = await runPriceSync({
      cards, setOrder: ["swsh7", "sv1", "sv2"], ppt: throwingPpt, tcgdex: fakeTcgdex, gradedActive: false,
      store, storage, date: "2026-07-06"
    });
    expect(rows).toHaveLength(3);
    for (const r of rows) {
      expect(r.psa3).toBeNull();
      expect(r.psa7).toBeNull();
      expect(r.psa9).toBeNull();
      expect(r.psa10).toBeNull();
    }
    expect(rows.find(r => r.cardId === "swsh7-215")?.rawUsd).toBe(92.5);
    expect(rows.find(r => r.cardId === "swsh7-215")?.rawEur).toBe(80.1);
  });
});

describe("runPriceSync per-run cap", () => {
  const mkCards = (ids: string[]): CatalogCardRef[] =>
    ids.map((setId) => ({ id: `${setId}-1`, setId, setName: setId.toUpperCase(), localId: "1", name: `${setId} card` }));
  // returns one priced card for any requested set, so every queued set counts as synced
  const capFakeTcgdex = {
    getSetCards: async (setId: string): Promise<TcgdexCard[]> => [{
      id: `${setId}-1`, localId: "1", name: `${setId} card`, hp: null, types: [], rarity: null, artist: null,
      text: "", imageBase: null, rawUsd: 1.0, rawEur: 0.5,
    }],
  } as unknown as TcgdexClient;
  const noPpt = { getSetPrices: () => { throw new Error("PPT must not be called"); } } as unknown as PptClient;

  it("caps the number of sets synced per run to maxRotationSetsPerRun", async () => {
    const setOrder = ["a", "b", "c", "d", "e"];
    const store = new MemStore([]);
    const { syncedSets } = await runPriceSync({
      cards: mkCards(setOrder), setOrder, ppt: noPpt, tcgdex: capFakeTcgdex, gradedActive: false,
      store, storage: new MemStorage(), date: "2026-07-07", maxRotationSetsPerRun: 2,
    });
    expect(syncedSets).toEqual(["a", "b"]);
    expect(store.cursor).toBe(2);
  });

  it("always syncs priority sets even when the rotation cap is smaller", async () => {
    const setOrder = ["a", "b", "c", "d", "e"];
    const store = new MemStore(["e"]);
    const { syncedSets } = await runPriceSync({
      cards: mkCards(setOrder), setOrder, ppt: noPpt, tcgdex: capFakeTcgdex, gradedActive: false,
      store, storage: new MemStorage(), date: "2026-07-07", maxRotationSetsPerRun: 1,
    });
    expect(syncedSets).toContain("e"); // priority always synced
    expect(syncedSets).toContain("a"); // first rotation set
    expect(syncedSets).toHaveLength(2); // priority not counted against the rotation cap
  });

  it("rotates through all sets across successive capped runs", async () => {
    const setOrder = ["a", "b", "c", "d", "e"];
    const store = new MemStore([]);
    const storage = new MemStorage();
    const seen = new Set<string>();
    for (let run = 0; run < 3; run++) {
      const { syncedSets } = await runPriceSync({
        cards: mkCards(setOrder), setOrder, ppt: noPpt, tcgdex: capFakeTcgdex, gradedActive: false,
        store, storage, date: `2026-07-1${run}`, maxRotationSetsPerRun: 2,
      });
      syncedSets.forEach((s) => seen.add(s));
    }
    expect([...seen].sort()).toEqual(["a", "b", "c", "d", "e"]); // full coverage over runs
  });

  it("without maxRotationSetsPerRun, syncs every set (backward compatible)", async () => {
    const setOrder = ["a", "b", "c"];
    const store = new MemStore([]);
    const { syncedSets } = await runPriceSync({
      cards: mkCards(setOrder), setOrder, ppt: noPpt, tcgdex: capFakeTcgdex, gradedActive: false,
      store, storage: new MemStorage(), date: "2026-07-07",
    });
    expect([...syncedSets].sort()).toEqual(["a", "b", "c"]);
  });
});

describe("prioritySetIdsFrom", () => {
  it("derives set ids from valid entry cardIds and want doc ids", () => {
    expect(prioritySetIdsFrom(["swsh7-215", "sv1-1"], ["sv2-1"])).toEqual(
      expect.arrayContaining(["swsh7", "sv1", "sv2"])
    );
  });

  it("skips undefined entry cardIds instead of throwing", () => {
    expect(() => prioritySetIdsFrom([undefined, "sv1-1"], [])).not.toThrow();
    expect(prioritySetIdsFrom([undefined, "sv1-1"], [])).toEqual(["sv1"]);
  });

  it("skips non-string entry cardIds instead of throwing", () => {
    expect(() => prioritySetIdsFrom([42, { cardId: "sv1-1" }, null], [])).not.toThrow();
    expect(prioritySetIdsFrom([42, { cardId: "sv1-1" }, null], [])).toEqual([]);
  });

  it("skips string entry cardIds without a '-' separator", () => {
    expect(prioritySetIdsFrom(["noseparator", "sv1-1"], [])).toEqual(["sv1"]);
  });
});
