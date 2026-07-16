import { describe, it, expect } from "vitest";
import { PptClient, CreditBudget } from "../src/upstream/ppt";
import { MinuteRateLimiter } from "../src/upstream/rate-limiter";

/** Build a mock fetch Response with case-insensitive headers.get(). */
function resp(opts: { status?: number; headers?: Record<string, string>; body?: unknown }) {
  const h = opts.headers ?? {};
  const lower: Record<string, string> = {};
  for (const [k, v] of Object.entries(h)) lower[k.toLowerCase()] = v;
  return {
    ok: (opts.status ?? 200) >= 200 && (opts.status ?? 200) < 300,
    status: opts.status ?? 200,
    headers: { get: (name: string) => (name.toLowerCase() in lower ? lower[name.toLowerCase()] : null) },
    json: async () => opts.body ?? { data: [] },
  } as any;
}

const OK = { body: { data: [{ cardNumber: "1", name: "X", prices: { market: 1 } }] } };

/** Records sleep durations and returns instantly (no real waiting in tests). */
function recorder() {
  const sleeps: number[] = [];
  const sleep = async (ms: number) => { sleeps.push(ms); };
  return { sleeps, sleep };
}

describe("PptClient rate-limit handling", () => {
  it("honors Retry-After exactly on a 429, then succeeds", async () => {
    const { sleeps, sleep } = recorder();
    const seq = [resp({ status: 429, headers: { "retry-after": "30" } }), resp(OK)];
    let i = 0;
    const client = new PptClient("k", new CreditBudget(100), async () => seq[i++], sleep);
    const cards = await client.getSetCards("Some Set");
    expect(cards).toHaveLength(1);
    expect(sleeps).toEqual([30_000]); // waited exactly Retry-After seconds, once
  });

  it("falls back to a 60s wait when a 429 has no Retry-After", async () => {
    const { sleeps, sleep } = recorder();
    const seq = [resp({ status: 429 }), resp(OK)];
    let i = 0;
    const client = new PptClient("k", new CreditBudget(100), async () => seq[i++], sleep);
    await client.getSetCards("s");
    expect(sleeps).toEqual([60_000]);
  });

  it("gives up (throws) after too many 429s instead of hammering", async () => {
    const { sleep } = recorder();
    const client = new PptClient("k", new CreditBudget(100), async () => resp({ status: 429, headers: { "retry-after": "1" } }), sleep);
    await expect(client.getSetCards("s")).rejects.toThrow(/PPT 429 .*gave up/);
  });

  it("proactively pauses when X-RateLimit-Minute-Remaining is below the 30 floor", async () => {
    const { sleeps, sleep } = recorder();
    const client = new PptClient("k", new CreditBudget(100),
      async () => resp({ status: 200, headers: { "x-ratelimit-minute-remaining": "10", "retry-after": "12" }, body: OK.body }), sleep);
    await client.getSetCards("s");
    expect(sleeps).toEqual([12_000]); // paused for the window reset before returning
  });

  it("does not pause when the minute budget is healthy", async () => {
    const { sleeps, sleep } = recorder();
    const client = new PptClient("k", new CreditBudget(100),
      async () => resp({ status: 200, headers: { "x-ratelimit-minute-remaining": "40" }, body: OK.body }), sleep);
    await client.getSetCards("s");
    expect(sleeps).toEqual([]);
  });

  it("ignores the legacy x-ratelimit-remaining header name (regression guard for the bug fix)", async () => {
    const { sleeps, sleep } = recorder();
    const client = new PptClient("k", new CreditBudget(100),
      async () => resp({ status: 200, headers: { "x-ratelimit-remaining": "0" }, body: OK.body }), sleep);
    await client.getSetCards("s");
    expect(sleeps).toEqual([]); // the old name must NOT trigger a pause anymore
  });

  it("routes requests through the injected MinuteRateLimiter (spacing enforced)", async () => {
    // A fixed clock (recorder()'s generic sleep never advances it) would make the limiter's
    // acquire() retry loop spin forever once the window fills — mirror rate-limiter.test.ts's
    // fakeClock and advance `t` on every sleep so the wait actually ages the window out.
    const sleeps: number[] = [];
    let t = 0;
    const sleep = async (ms: number) => { t += ms; sleeps.push(ms); };
    const limiter = new MinuteRateLimiter(45, () => t); // cost defaults to 1 per request
    const client = new PptClient("k", new CreditBudget(1000),
      async () => resp({ status: 200, body: OK.body }), sleep, limiter);
    for (let i = 0; i < 45; i++) await client.getSetCards("s"); // 45 * cost 1 = 45, all at t=0
    expect(sleeps).toEqual([]);
    await client.getSetCards("s"); // 46th → bucket makes it wait a full window
    expect(sleeps).toEqual([60_000]);
  });

  it("works with responses that have no rate-limit headers (regression)", async () => {
    const { sleeps, sleep } = recorder();
    // Response object without a headers property at all.
    const bare = { ok: true, status: 200, json: async () => OK.body } as any;
    const client = new PptClient("k", new CreditBudget(100), async () => bare, sleep);
    const cards = await client.getSetCards("s");
    expect(cards).toHaveLength(1);
    expect(sleeps).toEqual([]);
  });
});
