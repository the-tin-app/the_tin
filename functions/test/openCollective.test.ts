import { describe, it, expect, vi } from "vitest";
import { fetchOcStats } from "../src/upstream/openCollective";

function okResponse(payload: unknown) {
  return { ok: true, status: 200, json: async () => payload };
}

describe("fetchOcStats", () => {
  it("parses balance and month-to-date donations from GraphQL response", async () => {
    const fetchFn = vi.fn().mockResolvedValue(okResponse({
      data: { account: { stats: {
        balance: { valueInCents: 42000 },
        totalAmountReceived: { valueInCents: 8100 },
      } } },
    }));
    const stats = await fetchOcStats("the-tin", "2026-07-01T00:00:00Z", fetchFn);
    expect(stats).toEqual({ balanceCents: 42000, raisedThisMonthCents: 8100 });
    const [url, init] = fetchFn.mock.calls[0];
    expect(url).toBe("https://api.opencollective.com/graphql/v2");
    expect(init.method).toBe("POST");
    const body = JSON.parse(init.body);
    expect(body.variables).toEqual({ slug: "the-tin", dateFrom: "2026-07-01T00:00:00Z" });
  });

  it("throws on HTTP error", async () => {
    const fetchFn = vi.fn().mockResolvedValue({ ok: false, status: 500, json: async () => ({}) });
    await expect(fetchOcStats("the-tin", "2026-07-01T00:00:00Z", fetchFn))
      .rejects.toThrow("Open Collective API error: 500");
  });

  it("throws when the account is missing (bad slug)", async () => {
    const fetchFn = vi.fn().mockResolvedValue(okResponse({ data: { account: null } }));
    await expect(fetchOcStats("nope", "2026-07-01T00:00:00Z", fetchFn))
      .rejects.toThrow("Open Collective account not found: nope");
  });
});
