import { describe, it, expect } from "vitest";
import { TcgdexClient } from "../src/upstream/tcgdex";
import { refreshJaMetadata } from "../scripts/fetch-ja-metadata";
import type { JaMetadata } from "../src/pipeline/japanese";

/**
 * The economics are the feature here. A full Japanese sweep is ~16,400 requests (177 sets,
 * 16,192 cards, measured 2026-07-29) against a nightly whose English metadata costs ZERO — it
 * reads a local git clone. Doing that every night would be the largest single thing the nightly
 * does, so these tests pin the thing that stops it: `/sets` alone reports card counts, so an
 * unchanged set is never re-fetched.
 */
function fakeApi(sets: { id: string; total: number }[], onCall: (url: string) => void) {
  return async (url: string) => {
    onCall(url);
    if (url.endsWith("/sets")) {
      return json(sets.map((s) => ({ id: s.id, name: `set ${s.id}`, cardCount: { total: s.total, official: s.total } })));
    }
    const setId = url.split("/sets/")[1];
    if (setId) {
      const total = sets.find((s) => s.id === setId)?.total ?? 0;
      return json({ cards: Array.from({ length: total }, (_, i) => ({ id: `${setId}-${i + 1}` })) });
    }
    const cardId = url.split("/cards/")[1];
    const localId = cardId.split("-").pop()!;
    return json({ id: cardId, localId, name: `card ${cardId}`, pricing: { cardmarket: { trend: 1 } } });
  };
}

const json = (body: unknown) => new Response(JSON.stringify(body), { status: 200 }) as any;

describe("Japanese metadata cache", () => {
  it("fetches everything on the first run", async () => {
    const calls: string[] = [];
    const client = new TcgdexClient(fakeApi([{ id: "SV1a", total: 2 }], (u) => calls.push(u)), "ja");

    const { meta, fetchedSets } = await refreshJaMetadata(client, null);
    expect(fetchedSets).toEqual(["SV1a"]);
    expect(meta.cards.map((c) => c.id)).toEqual(["ja-SV1a-1", "ja-SV1a-2"]);
    expect(calls.every((u) => u.includes("/v2/ja/"))).toBe(true);
  });

  /// The whole point: a quiet night is ONE request. Anything else and this feature costs the
  /// nightly 16k requests forever.
  it("costs exactly one request when nothing upstream changed", async () => {
    const calls: string[] = [];
    const client = new TcgdexClient(fakeApi([{ id: "SV1a", total: 2 }], (u) => calls.push(u)), "ja");
    const first = await refreshJaMetadata(client, null);

    calls.length = 0;
    const second = await refreshJaMetadata(client, first.meta);
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatch(/\/sets$/);
    expect(second.fetchedSets).toEqual([]);
    expect(second.reusedSets).toBe(1);
    expect(second.meta.cards).toEqual(first.meta.cards);
  });

  /// The cache holds NAMESPACED ids while the API reports raw ones. Comparing the two directly is
  /// the bug that would make every set look new every night — a silent return to 16k requests.
  it("matches the cache on namespaced ids, not raw upstream ids", async () => {
    const client = new TcgdexClient(fakeApi([{ id: "neo1", total: 1 }], () => {}), "ja");
    const first = await refreshJaMetadata(client, null);
    expect(first.meta.cards[0].setId).toBe("ja-neo1");
    const second = await refreshJaMetadata(client, first.meta);
    expect(second.fetchedSets).toEqual([]);
  });

  it("re-fetches only the set whose card count changed", async () => {
    let sets = [{ id: "A", total: 1 }, { id: "B", total: 1 }];
    const calls: string[] = [];
    const api = async (url: string) => fakeApi(sets, (u) => calls.push(u))(url);
    const client = new TcgdexClient(api, "ja");
    const first = await refreshJaMetadata(client, null);

    sets = [{ id: "A", total: 1 }, { id: "B", total: 3 }];
    calls.length = 0;
    const second = await refreshJaMetadata(client, first.meta);
    expect(second.fetchedSets).toEqual(["B"]);
    expect(second.reusedSets).toBe(1);
    expect(second.meta.cards.filter((c) => c.setId === "ja-B")).toHaveLength(3);
    expect(second.meta.cards.filter((c) => c.setId === "ja-A")).toHaveLength(1);
  });

  /// One failing set must not cost the other 176. A partial Japanese catalogue is strictly better
  /// than a nightly that produces nothing.
  it("keeps a failing set's cached cards instead of losing them", async () => {
    let failing = false;
    const client = new TcgdexClient(async (url: string) => {
      if (failing && url.includes("/sets/B")) throw new Error("upstream down");
      return fakeApi([{ id: "A", total: 1 }, { id: "B", total: 1 }], () => {})(url);
    }, "ja");
    const first = await refreshJaMetadata(client, null);

    failing = true;
    const second = await refreshJaMetadata(client, first.meta, { force: true });
    expect(second.meta.cards.filter((c) => c.setId === "ja-B")).toHaveLength(1);
    expect(second.meta.cards.filter((c) => c.setId === "ja-A")).toHaveLength(1);
  });

  /// An upstream set with no cards is a placeholder, not a read we failed. Fetching it every
  /// night forever is the one request that can never pay off.
  it("does not re-fetch an empty set every night", async () => {
    const calls: string[] = [];
    const client = new TcgdexClient(fakeApi([{ id: "EMPTY", total: 0 }], (u) => calls.push(u)), "ja");
    const first = await refreshJaMetadata(client, null);
    expect(first.meta.cards).toHaveLength(0);

    calls.length = 0;
    await refreshJaMetadata(client, first.meta);
    expect(calls).toHaveLength(1);
  });

  it("--force re-fetches even an unchanged set, for the times content moved but counts didn't",
     async () => {
    const calls: string[] = [];
    const client = new TcgdexClient(fakeApi([{ id: "SV1a", total: 1 }], (u) => calls.push(u)), "ja");
    const first = await refreshJaMetadata(client, null);

    calls.length = 0;
    const second = await refreshJaMetadata(client, first.meta, { force: true });
    expect(second.fetchedSets).toEqual(["SV1a"]);
    expect(calls.length).toBeGreaterThan(1);
  });
});

/** Shape guard: the cache must stay the shape `build-catalog` concatenates onto English. */
describe("cache shape", () => {
  it("is { generatedAt, sets, cards }", async () => {
    const client = new TcgdexClient(fakeApi([{ id: "SV1a", total: 1 }], () => {}), "ja");
    const { meta } = await refreshJaMetadata(client, null);
    const keys = Object.keys(meta).sort();
    expect(keys).toEqual(["cards", "generatedAt", "sets"] satisfies (keyof JaMetadata)[]);
  });
});
