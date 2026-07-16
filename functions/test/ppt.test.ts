import { describe, it, expect } from "vitest";
import { PptClient, CreditBudget, CreditBudgetExceeded, parseCreditBudget } from "../src/upstream/ppt";

const pptResponse = {
  data: [
    {
      tcgPlayerId: 246807, name: "Rayquaza VMAX", setName: "Evolving Skies", cardNumber: "215",
      prices: { market: 92.5, low: 80.0 },
      ebay: {
        salesByGrade: {
          psa10: { smartMarketPrice: { price: 44.62 }, medianPrice: 43, averagePrice: 41.6 },
          psa9: { medianPrice: 8.5 },
        },
      },
    },
    {
      tcgPlayerId: 246700, name: "Umbreon V", setName: "Evolving Skies", cardNumber: "94",
      prices: { market: 30.1 }
    }
  ]
};

const okFetch = async (url: string, init?: RequestInit) => {
  okFetch.lastUrl = url; okFetch.lastInit = init;
  return new Response(JSON.stringify(pptResponse), { status: 200 });
};
okFetch.lastUrl = ""; okFetch.lastInit = undefined as RequestInit | undefined;

describe("PptClient", () => {
  it("fetches set prices, maps raw + graded (real ebay.salesByGrade shape), sends bearer auth", async () => {
    const budget = new CreditBudget(1000);
    const c = new PptClient("KEY123", budget, okFetch);
    const prices = await c.getSetPrices("Evolving Skies", { graded: true });
    expect(okFetch.lastUrl).toContain("fetchAllInSet=true");
    expect(okFetch.lastUrl).toContain("includeEbay=true");
    expect((okFetch.lastInit!.headers as Record<string, string>).Authorization).toBe("Bearer KEY123");
    expect(prices[0]).toEqual({
      tcgPlayerId: 246807, name: "Rayquaza VMAX", setName: "Evolving Skies",
      cardNumber: "215", raw: 92.5, graded: { psa10: 44.62, psa9: 8.5 }
    });
    expect(prices[0].graded.psa10).toBe(44.62);
    expect(prices[0].graded.psa9).toBe(8.5);
    expect(prices[1].raw).toBe(30.1);
    expect(prices[1].graded).toEqual({});
    expect(budget.spent).toBe(4); // 2 cards × (1 + 1 graded)
  });

  it("halts when the credit budget would be exceeded", async () => {
    const budget = new CreditBudget(3);
    const c = new PptClient("KEY123", budget, okFetch);
    await expect(c.getSetPrices("Evolving Skies", { graded: true })).rejects.toThrow(CreditBudgetExceeded);
  });
});

describe("CreditBudget constructor", () => {
  it("throws for a non-finite or non-positive limit", () => {
    expect(() => new CreditBudget(NaN)).toThrow();
    expect(() => new CreditBudget(Infinity)).toThrow();
    expect(() => new CreditBudget(0)).toThrow();
    expect(() => new CreditBudget(-5)).toThrow();
  });

  it("accepts a positive finite limit", () => {
    expect(() => new CreditBudget(1000)).not.toThrow();
  });
});

describe("parseCreditBudget", () => {
  it("falls back to 15000 when undefined", () => {
    expect(parseCreditBudget(undefined)).toBe(15000);
  });
  it("falls back to 15000 when empty string", () => {
    expect(parseCreditBudget("")).toBe(15000);
  });
  it("falls back to 15000 when non-numeric", () => {
    expect(parseCreditBudget("abc")).toBe(15000);
  });
  it("parses a valid positive numeric string", () => {
    expect(parseCreditBudget("2000")).toBe(2000);
  });
  it("falls back to 15000 when zero", () => {
    expect(parseCreditBudget("0")).toBe(15000);
  });
  it("falls back to 15000 when negative", () => {
    expect(parseCreditBudget("-5")).toBe(15000);
  });
});
