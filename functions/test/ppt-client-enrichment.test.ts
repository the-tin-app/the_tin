import { describe, it, expect } from "vitest";
import { PptClient, CreditBudget } from "../src/upstream/ppt";
import { MinuteRateLimiter } from "../src/upstream/rate-limiter";

const noSleep = async () => {};
function res(body: any, headers: Record<string, string> = {}) {
  return { status: 200, ok: true, headers: { get: (h: string) => headers[h.toLowerCase()] ?? null }, json: async () => body };
}
function res403() {
  return { status: 403, ok: false, headers: { get: () => null }, json: async () => ({}) };
}

describe("PptClient.getSetEnrichment", () => {
  it("returns history+graded per card, spends 3 credits/card, reserves 30 minute-calls", async () => {
    let acquired = 0;
    const limiter = new MinuteRateLimiter(45, () => 0);
    const origAcquire = limiter.acquire.bind(limiter);
    (limiter as any).acquire = (cost: number, s: any) => { acquired = cost; return origAcquire(cost, s); };
    const budget = new CreditBudget(1000);
    const prices = {
      market: 100,
      primaryPrinting: "Holofoil",
      variants: { Holofoil: { "Near Mint": { price: 100 }, "Lightly Played": { price: 85 } } },
    };
    const body = { data: [
      { tcgPlayerId: 1, cardNumber: "4", name: "Charizard", prices,
        priceHistory: [{ date: "2026-07-01", price: 90 }],
        ebay: {
          salesByGrade: { psa10: { smartMarketPrice: { price: 450 } } },
          priceHistory: { psa10: { "2026-04-20": { average: 440 } } },
        } },
    ]};
    const fetchFn = async () => res(body, { "x-ratelimit-minute-remaining": "59" }) as any;
    const c = new PptClient("k", budget, fetchFn, noSleep, limiter);
    const cards = await c.getSetEnrichment("Base");
    expect(acquired).toBe(30);
    expect(budget.spent).toBe(3);
    expect(cards[0].gradedLatest).toEqual({ psa10: 450 });
    expect(cards[0].gradedSeries).toEqual([{ grade: "psa10", date: "2026-04-20", usd: 440 }]);
    expect(cards[0].priceHistory).toBeTruthy();
    expect(cards[0].pricesRaw).toEqual(prices); // raw prices carried through for all-conditions parsing
  });
});

describe("PptClient.getPopulation", () => {
  it("no ids → no call, []", async () => {
    let called = 0;
    const c = new PptClient("k", new CreditBudget(100), (async () => { called++; return res({}); }) as any, noSleep, new MinuteRateLimiter(45, () => 0));
    expect(await c.getPopulation([])).toEqual([]);
    expect(called).toBe(0);
  });
  it("throws PPT 403 (no retry) when not entitled", async () => {
    const c = new PptClient("k", new CreditBudget(100), (async () => res403()) as any, noSleep, new MinuteRateLimiter(45, () => 0));
    await expect(c.getPopulation([1, 2])).rejects.toThrow(/PPT 403/);
  });
  it("parses rows and spends 2 credits/card", async () => {
    const body = { data: [{ tcgPlayerId: "1", populationByGrader: { PSA: { g10: 5, totalPopulation: 5, gemRate: 100 } } }] };
    const budget = new CreditBudget(100);
    const c = new PptClient("k", budget, (async () => res(body)) as any, noSleep, new MinuteRateLimiter(45, () => 0));
    const rows = await c.getPopulation([1]);
    expect(rows[0]).toMatchObject({ tcgPlayerId: 1, grader: "PSA", grade: "g10", count: 5 });
    expect(budget.spent).toBe(2);
  });
});
