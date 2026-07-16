import { describe, it, expect } from "vitest";
import { runProbe } from "../src/pipeline/overnight-probe";

const headers = { minuteLimit: 60, minuteRemaining: 59, purchasedRemaining: 200000, dailyRemaining: 5000 };

describe("runProbe", () => {
  it("detects latest-only + population entitled", async () => {
    const client = {
      lastHeaders: headers,
      getSetEnrichment: async () => [{ ebayRaw: { salesByGrade: { psa10: { smartMarketPrice: { price: 450 } } } } }],
      getPopulation: async () => ({ data: { tcgPlayerId: "1", populationByGrader: { PSA: { g10: 1 } } } }),
    };
    const r = await runProbe(client as any, "Base", 1, "2026-07-08T00:00:00Z");
    expect(r).toMatchObject({ minuteLimit: 60, purchasedRemaining: 200000, gradedHistoryMode: "latest-only", populationEnabled: true });
  });
  it("detects a graded time-series and a 403 population lockout", async () => {
    const client = {
      lastHeaders: headers,
      getSetEnrichment: async () => [{ ebayRaw: { priceHistory: { psa10: { "2026-04-20": { average: 440 } } } } }],
      getPopulation: async () => { throw new Error("PPT 403 for population 1"); },
    };
    const r = await runProbe(client as any, "Base", 1, "2026-07-08T00:00:00Z");
    expect(r.gradedHistoryMode).toBe("timeseries");
    expect(r.populationEnabled).toBe(false);
  });
  it("rethrows non-403 population errors", async () => {
    const client = { lastHeaders: headers, getSetEnrichment: async () => [{ ebayRaw: {} }],
      getPopulation: async () => { throw new Error("PPT 500 for population 1"); } };
    await expect(runProbe(client as any, "Base", 1, "2026-07-08T00:00:00Z")).rejects.toThrow(/500/);
  });
  it("skips population entirely when no tcgplayer_id is available, without throwing", async () => {
    let getPopulationCalls = 0;
    const client = {
      lastHeaders: headers,
      getSetEnrichment: async () => [{ ebayRaw: { salesByGrade: { psa10: { smartMarketPrice: { price: 450 } } } } }],
      getPopulation: async () => { getPopulationCalls++; return {}; },
    };
    const r = await runProbe(client as any, "Base", null, "2026-07-08T00:00:00Z");
    expect(getPopulationCalls).toBe(0);
    expect(r.populationEnabled).toBe(false);
    expect(r.gradedHistoryMode).toBe("latest-only");
  });
});
