import { describe, it, expect } from "vitest";
import { PptClient, CreditBudget } from "../src/upstream/ppt";
import { MinuteRateLimiter } from "../src/upstream/rate-limiter";

const BODY = {
  data: [
    { tcgPlayerId: 246807, cardNumber: "215", name: "Umbreon VMAX",
      prices: { market: 92.5 }, priceHistory: [{ date: "2026-01-05", price: 88 }] },
    { tcgPlayerId: null, cardNumber: "94", name: "Umbreon V", prices: {}, priceHistory: null },
  ],
};

function client(fetchFn: any, budget = new CreditBudget(1000), limiter?: MinuteRateLimiter, sleep?: any) {
  return new PptClient("KEY", budget, fetchFn, sleep, limiter);
}

describe("getSetHistory", () => {
  it("requests includeHistory/days/maxDataPoints and passes priceHistory through", async () => {
    let url = "";
    const cards = await client(async (u: string) => {
      url = u;
      return { ok: true, status: 200, headers: { get: () => null }, json: async () => BODY } as any;
    }).getSetHistory("Evolving Skies", 26);
    expect(url).toContain("set=Evolving+Skies");
    expect(url).toContain("fetchAllInSet=true");
    expect(url).toContain("includeHistory=true");
    expect(url).toContain("days=730");
    expect(url).toContain("maxDataPoints=104");
    expect(cards).toHaveLength(2);
    expect(cards[0]).toEqual({ tcgPlayerId: 246807, cardNumber: "215", name: "Umbreon VMAX",
      priceHistory: [{ date: "2026-01-05", price: 88 }] });
    expect(cards[1].priceHistory).toBeNull();
  });

  it("spends 2 credits per card (1 base + 1 includeHistory)", async () => {
    const budget = new CreditBudget(1000);
    await client(async () => ({ ok: true, status: 200, headers: { get: () => null }, json: async () => BODY } as any), budget)
      .getSetHistory("x", 20);
    expect(budget.spent).toBe(4); // 2 cards * 2
  });

  it("reserves the worst-case 30-call cap in the limiter regardless of hint", async () => {
    // A fixed clock would make the limiter's acquire() retry loop spin forever once the window
    // fills (see ppt-ratelimit.test.ts) — advance `t` on every sleep so the wait actually ages
    // the window out.
    const sleeps: number[] = [];
    let t = 0;
    const sleep = async (ms: number) => { t += ms; sleeps.push(ms); };
    const limiter = new MinuteRateLimiter(45, () => t);
    const fetchFn = async () => ({ ok: true, status: 200, headers: { get: () => null }, json: async () => BODY } as any);
    const c = client(fetchFn, new CreditBudget(1000), limiter, sleep);
    // Even with a tiny hint, the reserved cost is the fixed 30-call cap (never derived from the
    // hint) — because PPT's true set size, and thus its real cost, is unknown up front and can
    // exceed our catalog's count for aliased/promo sets. So two calls still reserve 30+30=60>45.
    await c.getSetHistory("small", 1);
    await c.getSetHistory("small2", 1); // 30 + 30 = 60 > 45 → waits a window
    expect(sleeps).toEqual([60_000]);
  });
});
