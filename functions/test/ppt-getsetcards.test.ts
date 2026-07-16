import { describe, it, expect } from "vitest";
import { PptClient, CreditBudget } from "../src/upstream/ppt";

const SAMPLE = {
  data: [
    {
      externalCatalogId: "sv02-271", cardNumber: "271/193", name: "Meowscarada ex - 271/193",
      imageCdnUrl: "https://tcgplayer-cdn.tcgplayer.com/product/1_in_800x800.jpg",
      imageCdnUrl800: "https://tcgplayer-cdn.tcgplayer.com/product/1_in_800x800.jpg",
      prices: { market: 9.53 },
    },
    { externalCatalogId: null, cardNumber: "5", name: "No Image Card", prices: {} },
  ],
};

function clientReturning(body: unknown) {
  const fetchFn = async () => ({ ok: true, status: 200, json: async () => body }) as any;
  return new PptClient("k", new CreditBudget(1000), fetchFn);
}

describe("getSetCards", () => {
  it("parses image url, market price, and identity fields", async () => {
    const cards = await clientReturning(SAMPLE).getSetCards("SV02: Paldea Evolved");
    expect(cards).toHaveLength(2);
    expect(cards[0]).toEqual({
      externalCatalogId: "sv02-271", cardNumber: "271/193", name: "Meowscarada ex - 271/193",
      imageUrl: "https://tcgplayer-cdn.tcgplayer.com/product/1_in_800x800.jpg", marketUsd: 9.53,
    });
    expect(cards[1].imageUrl).toBeNull();
    expect(cards[1].marketUsd).toBeNull();
  });

  it("spends one credit per returned card", async () => {
    const budget = new CreditBudget(1000);
    const fetchFn = async () => ({ ok: true, status: 200, json: async () => SAMPLE }) as any;
    await new PptClient("k", budget, fetchFn).getSetCards("x");
    expect(budget.spent).toBe(2);
  });

  it("throws on non-ok response", async () => {
    const fetchFn = async () => ({ ok: false, status: 500, json: async () => ({}) }) as any;
    await expect(new PptClient("k", new CreditBudget(1000), fetchFn).getSetCards("x")).rejects.toThrow(/PPT 500/);
  });
});
