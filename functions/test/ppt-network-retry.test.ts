import { describe, it, expect } from "vitest";
import { PptClient, CreditBudget, isTransientNetworkError } from "../src/upstream/ppt";
import { MinuteRateLimiter } from "../src/upstream/rate-limiter";

const noSleep = async () => {};
function res(body: any, headers: Record<string, string> = {}) {
  return { status: 200, ok: true, headers: { get: (h: string) => headers[h.toLowerCase()] ?? null }, json: async () => body };
}

/** The exact shape undici throws on a connect timeout: TypeError("fetch failed") wrapping
 *  ConnectTimeoutError{code} via .cause (observed in the 2026-07-16 nightly failure). */
function undiciConnectTimeout(): Error {
  const cause = Object.assign(new Error("Connect Timeout Error (attempted addresses: 216.150.1.1:443, timeout: 10000ms)"), {
    code: "UND_ERR_CONNECT_TIMEOUT",
  });
  return Object.assign(new TypeError("fetch failed"), { cause });
}

describe("isTransientNetworkError", () => {
  it("matches undici fetch-failed with nested cause code", () => {
    expect(isTransientNetworkError(undiciConnectTimeout())).toBe(true);
  });
  it("matches bare ECONNRESET-style errors", () => {
    expect(isTransientNetworkError(Object.assign(new Error("read ECONNRESET"), { code: "ECONNRESET" }))).toBe(true);
  });
  it("does NOT match PPT status errors or generic errors", () => {
    expect(isTransientNetworkError(new Error("PPT 429 for set Base"))).toBe(false);
    expect(isTransientNetworkError(new Error("PPT 403 for population 2"))).toBe(false);
    expect(isTransientNetworkError(new Error("unexpected token in JSON"))).toBe(false);
  });
});

describe("PptClient network retry", () => {
  it("retries a transient network error and succeeds", async () => {
    let calls = 0;
    const fetchFn = async () => {
      calls++;
      if (calls < 3) throw undiciConnectTimeout();
      return res({ data: [] }) as any;
    };
    const c = new PptClient("k", new CreditBudget(100), fetchFn, noSleep, new MinuteRateLimiter(45, () => 0));
    await expect(c.getSetCards("Base")).resolves.toEqual([]);
    expect(calls).toBe(3);
  });

  it("gives up after the retry ladder is exhausted (5 retries = 6 attempts)", async () => {
    let calls = 0;
    const fetchFn = async () => { calls++; throw undiciConnectTimeout(); };
    const c = new PptClient("k", new CreditBudget(100), fetchFn, noSleep, new MinuteRateLimiter(45, () => 0));
    await expect(c.getSetCards("Base")).rejects.toThrow(/fetch failed/);
    expect(calls).toBe(6);
  });

  it("throws non-transient fetch errors immediately (no retry)", async () => {
    let calls = 0;
    const fetchFn = async () => { calls++; throw new Error("boom: programming bug"); };
    const c = new PptClient("k", new CreditBudget(100), fetchFn, noSleep, new MinuteRateLimiter(45, () => 0));
    await expect(c.getSetCards("Base")).rejects.toThrow(/boom/);
    expect(calls).toBe(1);
  });

  it("network retries do not consume the 429 Retry-After allowance", async () => {
    // 1 network failure, then two 429s, then success — must survive (429 allowance is 2 waits).
    const script = ["net", "429", "429", "ok"];
    let i = 0;
    const fetchFn = async () => {
      const step = script[i++];
      if (step === "net") throw undiciConnectTimeout();
      if (step === "429") return { status: 429, ok: false, headers: { get: () => null }, json: async () => ({}) } as any;
      return res({ data: [] }, { "x-ratelimit-minute-remaining": "59" }) as any;
    };
    const c = new PptClient("k", new CreditBudget(100), fetchFn, noSleep, new MinuteRateLimiter(45, () => 0));
    await expect(c.getSetCards("Base")).resolves.toEqual([]);
    expect(i).toBe(4);
  });
});
