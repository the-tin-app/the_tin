import { describe, it, expect } from "vitest";
import { fetchSponsorsStats, FetchLike } from "../src/upstream/githubSponsors";

const ok = (body: unknown): FetchLike => async () => ({ ok: true, status: 200, json: async () => body });

const payload = (org: unknown) => ({ data: { organization: org } });

describe("fetchSponsorsStats", () => {
  it("posts an authed GraphQL query to GitHub", async () => {
    let seen: { url?: string; headers?: Record<string, string>; body?: string } = {};
    const fetchFn: FetchLike = async (url, init) => {
      seen = { url, headers: init?.headers, body: init?.body };
      return { ok: true, status: 200, json: async () => payload({ monthlyEstimatedSponsorsIncomeInCents: 0, sponsorsListing: null }) };
    };
    await fetchSponsorsStats("the-tin-app", "tok", fetchFn);
    expect(seen.url).toBe("https://api.github.com/graphql");
    expect(seen.headers?.Authorization).toBe("Bearer tok");
    expect(seen.headers?.["User-Agent"]).toBeTruthy(); // GitHub 403s UA-less requests
    expect(seen.body).toContain("the-tin-app");
  });

  it("reads the monthly income and the page's own monthly-amount goal", async () => {
    const stats = await fetchSponsorsStats("the-tin-app", "tok", ok(payload({
      monthlyEstimatedSponsorsIncomeInCents: 4200,
      sponsorsListing: { activeGoal: { kind: "MONTHLY_SPONSORSHIP_AMOUNT", targetValue: 150 } },
    })));
    expect(stats.monthlyIncomeCents).toBe(4200);
    expect(stats.goalCents).toBe(15000);
  });

  it("ignores a sponsor-count goal — a headcount is not a denominator in cents", async () => {
    const stats = await fetchSponsorsStats("the-tin-app", "tok", ok(payload({
      monthlyEstimatedSponsorsIncomeInCents: 500,
      sponsorsListing: { activeGoal: { kind: "TOTAL_SPONSORS_COUNT", targetValue: 25 } },
    })));
    expect(stats.goalCents).toBeNull();
  });

  it("returns zero income and no goal for a listing with neither", async () => {
    const stats = await fetchSponsorsStats("the-tin-app", "tok", ok(payload({ sponsorsListing: { activeGoal: null } })));
    expect(stats).toEqual({ monthlyIncomeCents: 0, goalCents: null });
  });

  it("throws on a GraphQL errors array (scope problems arrive as HTTP 200)", async () => {
    await expect(fetchSponsorsStats("the-tin-app", "tok", ok({ errors: [{ message: "INSUFFICIENT_SCOPES" }] })))
      .rejects.toThrow("INSUFFICIENT_SCOPES");
  });

  it("throws on an HTTP failure", async () => {
    const fetchFn: FetchLike = async () => ({ ok: false, status: 401, json: async () => ({}) });
    await expect(fetchSponsorsStats("the-tin-app", "tok", fetchFn)).rejects.toThrow("GitHub API error: 401");
  });

  it("throws when the org has no sponsors presence at all", async () => {
    await expect(fetchSponsorsStats("nope", "tok", ok(payload(null)))).rejects.toThrow("not found: nope");
  });
});
