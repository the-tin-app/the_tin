import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { parseLatestGraded, detectGradedHistoryMode, parseGradedHistory } from "../src/pipeline/ppt-graded";
import { parseWeeklyHistory } from "../src/pipeline/ppt-history";

// Real PPT shapes (confirmed by the live-captured fixture, see ppt-enrichment-sample.json).
const salesByGradeOnly = {
  salesByGrade: {
    psa9: { count: 1, averagePrice: 120, medianPrice: 118 },
    psa10: { count: 14, averagePrice: 400, medianPrice: 420, smartMarketPrice: { price: 450, confidence: "high" } },
  },
};
const withTimeseries = {
  salesByGrade: salesByGradeOnly.salesByGrade,
  priceHistory: {
    psa10: { "2026-04-20": { average: 39.99, count: 1 } },
    psa9: {},
  },
};

describe("graded parsers", () => {
  it("parseLatestGraded prefers smartMarketPrice.price, then medianPrice, then averagePrice", () => {
    expect(parseLatestGraded(withTimeseries)).toEqual({ psa9: 118, psa10: 450 }); // psa9 has no smartMarketPrice → falls back to medianPrice (118)
  });

  it("parseLatestGraded returns {} when salesByGrade is missing/not an object", () => {
    expect(parseLatestGraded({})).toEqual({});
    expect(parseLatestGraded({ salesByGrade: "nope" })).toEqual({});
  });

  it("detects latest-only vs timeseries from ebay.priceHistory", () => {
    expect(detectGradedHistoryMode(salesByGradeOnly)).toBe("latest-only");
    expect(detectGradedHistoryMode(withTimeseries)).toBe("timeseries");
    expect(detectGradedHistoryMode({ priceHistory: { psa10: { "2026-04-20": { average: 39.99 } } } })).toBe("timeseries");
  });

  it("parseGradedHistory flattens ebay.priceHistory[grade][date].average", () => {
    expect(parseGradedHistory(salesByGradeOnly)).toEqual([]);
    expect(parseGradedHistory(withTimeseries)).toEqual([
      { grade: "psa10", date: "2026-04-20", usd: 39.99 },
    ]);
  });

  it("tolerates garbage", () => {
    expect(parseLatestGraded(null)).toEqual({});
    expect(parseLatestGraded(undefined)).toEqual({});
    expect(parseGradedHistory(undefined)).toEqual([]);
    expect(parseGradedHistory("nope")).toEqual([]);
    expect(detectGradedHistoryMode({})).toBe("latest-only");
    expect(detectGradedHistoryMode(null)).toBe("latest-only");
  });
});

describe("fixture-driven: real captured PPT enrichment sample", () => {
  const fixture = JSON.parse(
    fs.readFileSync(path.join(__dirname, "fixtures", "ppt-enrichment-sample.json"), "utf8"),
  );
  const cardA = fixture.data[0]; // "Metal Energy (Secret)" — has salesByGrade + ebay.priceHistory + raw conditions history
  const cardB = fixture.data[1]; // "Treasure Energy" — raw history only, no ebay

  it("cardA: parseLatestGraded picks psa10 via smartMarketPrice.price", () => {
    const latest = parseLatestGraded(cardA.ebay);
    expect(latest.psa10).toBeCloseTo(44.62, 2);
    expect(latest.psa9).toBeCloseTo(8.5, 2);
  });

  it("cardA: detectGradedHistoryMode is timeseries and parseGradedHistory is non-empty", () => {
    expect(detectGradedHistoryMode(cardA.ebay)).toBe("timeseries");
    const hist = parseGradedHistory(cardA.ebay);
    expect(hist.length).toBeGreaterThan(0);
    expect(hist.some((p) => p.grade === "psa10")).toBe(true);
  });

  it("cardA: parseWeeklyHistory on raw priceHistory (nested conditions shape) is non-empty", () => {
    expect(parseWeeklyHistory(cardA.priceHistory).length).toBeGreaterThan(0);
  });

  it("cardB: no ebay → empty graded results, but raw history still parses", () => {
    expect(parseLatestGraded(cardB.ebay)).toEqual({});
    expect(parseGradedHistory(cardB.ebay)).toEqual([]);
    expect(detectGradedHistoryMode(cardB.ebay)).toBe("latest-only");
    expect(parseWeeklyHistory(cardB.priceHistory).length).toBeGreaterThan(0);
  });
});
