import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseWeeklyHistory, parseConditionHistory, parseLatestByCondition, parseLatestByVariant } from "../src/pipeline/ppt-history";

describe("parseWeeklyHistory", () => {
  it("normalizes an array shape, dedups exact dates (latest wins), thins to >=6-day spacing", () => {
    const hist = [
      { date: "2026-01-05", price: 88 },
      { date: "2026-01-06", price: 88.2 }, // 1 day after 01-05 → thinned out
      { date: "2026-01-12", price: 90.5 },
      { date: "2026-01-12", price: 91 },   // exact-date dup → latest (91) wins
      { date: "2026-01-19", price: 92.5 },
    ];
    expect(parseWeeklyHistory(hist)).toEqual([
      { date: "2026-01-05", rawUsd: 88 },
      { date: "2026-01-12", rawUsd: 91 },
      { date: "2026-01-19", rawUsd: 92.5 },
    ]);
  });

  it("accepts an object-map shape { 'YYYY-MM-DD': price }", () => {
    expect(parseWeeklyHistory({ "2026-02-02": 10, "2026-02-09": 12 })).toEqual([
      { date: "2026-02-02", rawUsd: 10 },
      { date: "2026-02-09", rawUsd: 12 },
    ]);
  });

  it("accepts alternate field names (timestamp/market) and epoch-ms dates", () => {
    const jan5 = Date.UTC(2026, 0, 5), jan12 = Date.UTC(2026, 0, 12);
    expect(parseWeeklyHistory([
      { timestamp: jan5, market: 5 },
      { timestamp: jan12, market: 6 },
    ])).toEqual([
      { date: "2026-01-05", rawUsd: 5 },
      { date: "2026-01-12", rawUsd: 6 },
    ]);
  });

  it("accepts the real nested-conditions shape { conditions: { 'Near Mint': { history: [...] } } }", () => {
    const priceHistory = {
      conditions: {
        "Near Mint": {
          history: [
            { date: "2026-04-10T00:00:00.000Z", market: 10.89, volume: 4 },
            { date: "2026-04-17T00:00:00.000Z", market: 10.95, volume: 4 },
          ],
        },
        "Lightly Played": { history: [{ date: "2026-04-10T00:00:00.000Z", market: 9.5, volume: 1 }] },
      },
      totalDataPoints: 356,
    };
    expect(parseWeeklyHistory(priceHistory)).toEqual([
      { date: "2026-04-10", rawUsd: 10.89 },
      { date: "2026-04-17", rawUsd: 10.95 },
    ]);
  });

  it("falls back to the first condition when 'Near Mint' is absent", () => {
    const priceHistory = {
      conditions: {
        "Lightly Played": {
          history: [{ date: "2026-04-10T00:00:00.000Z", market: 9.5, volume: 1 }],
        },
      },
    };
    expect(parseWeeklyHistory(priceHistory)).toEqual([{ date: "2026-04-10", rawUsd: 9.5 }]);
  });

  it("returns [] for null/empty/garbage", () => {
    expect(parseWeeklyHistory(null)).toEqual([]);
    expect(parseWeeklyHistory([])).toEqual([]);
    expect(parseWeeklyHistory({})).toEqual([]);
    expect(parseWeeklyHistory("nope")).toEqual([]);
  });

  it("drops non-positive prices (0 and negative) but keeps positive points", () => {
    const hist = [
      { date: "2026-01-05", price: 88 },
      { date: "2026-01-12", price: 0 },    // bogus zero → dropped
      { date: "2026-01-19", price: -5 },   // negative → dropped
      { date: "2026-01-26", price: 92.5 },
    ];
    expect(parseWeeklyHistory(hist)).toEqual([
      { date: "2026-01-05", rawUsd: 88 },
      { date: "2026-01-26", rawUsd: 92.5 },
    ]);
  });
});

describe("parseConditionHistory", () => {
  it("returns one series per condition with points, skipping conditions with no points", () => {
    const priceHistory = {
      conditions: {
        "Near Mint": {
          history: [
            { date: "2026-04-10T00:00:00.000Z", market: 10.89, volume: 4 },
            { date: "2026-04-17T00:00:00.000Z", market: 10.95, volume: 4 },
          ],
        },
        "Heavily Played": { history: [] },
        "Lightly Played": {
          history: [{ date: "2026-04-10T00:00:00.000Z", market: 9.5, volume: 1 }],
        },
      },
    };
    const out = parseConditionHistory(priceHistory);
    const byCondition = new Map(out.map((s) => [s.condition, s.points]));
    expect(byCondition.has("Heavily Played")).toBe(false); // 0 points → skipped
    expect(byCondition.get("Near Mint")).toEqual([
      { date: "2026-04-10", rawUsd: 10.89 },
      { date: "2026-04-17", rawUsd: 10.95 },
    ]);
    expect(byCondition.get("Lightly Played")).toEqual([{ date: "2026-04-10", rawUsd: 9.5 }]);
  });

  it("returns [] for null/empty/garbage/non-object conditions", () => {
    expect(parseConditionHistory(null)).toEqual([]);
    expect(parseConditionHistory({})).toEqual([]);
    expect(parseConditionHistory({ conditions: "nope" })).toEqual([]);
    expect(parseConditionHistory("garbage")).toEqual([]);
  });
});

describe("parseLatestByCondition", () => {
  it("reads prices.variants[primaryPrinting][condition].price for each condition > 0", () => {
    const prices = {
      market: 10.57,
      primaryPrinting: "Holofoil",
      variants: {
        Holofoil: {
          "Near Mint": { price: 10.57 },
          "Heavily Played": { price: 5.8 },
          "Lightly Played": { price: 10.45 },
          Damaged: { price: 7.66 },
          "Moderately Played": { price: 9.69 },
        },
      },
    };
    const out = parseLatestByCondition(prices);
    const byCondition = new Map(out.map((c) => [c.condition, c.usd]));
    expect(byCondition.get("Near Mint")).toBe(10.57);
    expect(byCondition.get("Lightly Played")).toBe(10.45);
    expect(byCondition.get("Damaged")).toBe(7.66);
    expect(byCondition.get("Heavily Played")).toBe(5.8);
    expect(byCondition.get("Moderately Played")).toBe(9.69);
  });

  it("falls back to the first variant key when primaryPrinting is absent", () => {
    const prices = { variants: { Normal: { "Near Mint": { price: 1.23 } } } };
    expect(parseLatestByCondition(prices)).toEqual([{ condition: "Near Mint", usd: 1.23 }]);
  });

  it("excludes non-positive or non-finite prices", () => {
    const prices = {
      primaryPrinting: "Normal",
      variants: { Normal: { "Near Mint": { price: 0 }, Damaged: { price: -1 }, "Lightly Played": { price: 2 } } },
    };
    expect(parseLatestByCondition(prices)).toEqual([{ condition: "Lightly Played", usd: 2 }]);
  });

  it("returns [] for null/empty/garbage", () => {
    expect(parseLatestByCondition(null)).toEqual([]);
    expect(parseLatestByCondition({})).toEqual([]);
    expect(parseLatestByCondition({ variants: "nope" })).toEqual([]);
    expect(parseLatestByCondition("garbage")).toEqual([]);
  });
});

describe("parseLatestByVariant", () => {
  it("keeps EVERY printing (not just primaryPrinting), one NM price each", () => {
    const prices = {
      primaryPrinting: "Holofoil",
      variants: {
        Holofoil: { "Near Mint": { price: 95 }, "Lightly Played": { price: 80 } },
        "Reverse Holofoil": { "Near Mint": { price: 140 } },
        Normal: { "Near Mint": { price: 3 } },
      },
    };
    const out = parseLatestByVariant(prices);
    expect(new Map(out.map((v) => [v.printing, v.usd]))).toEqual(
      new Map([["Holofoil", 95], ["Reverse Holofoil", 140], ["Normal", 3]]),
    );
  });

  it("falls back to the first finite >0 condition when Near Mint is missing/unusable", () => {
    const prices = { variants: { Normal: { "Near Mint": { price: 0 }, "Lightly Played": { price: 2 } } } };
    expect(parseLatestByVariant(prices)).toEqual([{ printing: "Normal", usd: 2 }]);
  });

  it("skips printings with no usable price; returns [] for garbage", () => {
    expect(parseLatestByVariant({ variants: { Normal: { "Near Mint": { price: 0 } } } })).toEqual([]);
    expect(parseLatestByVariant(null)).toEqual([]);
    expect(parseLatestByVariant({ variants: "nope" })).toEqual([]);
  });
});

describe("fixture-driven: ppt-enrichment-sample.json cardA", () => {
  const fixture = JSON.parse(
    readFileSync(join(__dirname, "fixtures/ppt-enrichment-sample.json"), "utf8"),
  );
  const cardA = fixture.data[0]; // "Metal Energy (Secret)" — has all 5 conditions

  it("parseConditionHistory finds >=4 conditions with points", () => {
    const out = parseConditionHistory(cardA.priceHistory);
    expect(out.length).toBeGreaterThanOrEqual(4);
    const conditions = out.map((s) => s.condition);
    expect(conditions).toContain("Near Mint");
    expect(conditions).toContain("Lightly Played");
    expect(conditions).toContain("Moderately Played");
    expect(conditions).toContain("Damaged");
    // Heavily Played has an empty history array in the fixture → must be skipped
    expect(conditions).not.toContain("Heavily Played");
  });

  it("parseLatestByCondition returns all 5 conditions with correct prices", () => {
    const out = parseLatestByCondition(cardA.prices);
    const byCondition = new Map(out.map((c) => [c.condition, c.usd]));
    expect(byCondition.get("Near Mint")).toBeCloseTo(10.57);
    expect(byCondition.get("Lightly Played")).toBeCloseTo(10.45);
    expect(byCondition.get("Moderately Played")).toBeCloseTo(9.69);
    expect(byCondition.get("Damaged")).toBeCloseTo(7.66);
    expect(byCondition.get("Heavily Played")).toBeCloseTo(5.8);
    expect(out.length).toBe(5);
  });
});
