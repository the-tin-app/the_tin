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

/** The shape undici throws when the response STREAM dies part-way through — i.e. headers arrived
 *  and `fetch` resolved, then `res.json()` threw. Observed in the 2026-08-29 nightly, which lost a
 *  45-minute v57 sweep at 102/192 sets because the body read sat outside the retry ladder. */
function undiciBodyTerminated(): Error {
  const cause = Object.assign(new Error("other side closed"), { code: "UND_ERR_SOCKET" });
  return Object.assign(new TypeError("terminated"), { cause });
}
/** Variant with no enumerable transient code anywhere in the chain — matched on message alone. */
function undiciBodyTerminatedBare(): Error {
  return Object.assign(new TypeError("terminated"), {
    cause: Object.assign(new Error("Premature close"), { code: "ERR_STREAM_PREMATURE_CLOSE" }),
  });
}

describe("mid-body abort (regression: 2026-08-29 v57 sweep)", () => {
  it("classifies a terminated response stream as transient", () => {
    expect(isTransientNetworkError(undiciBodyTerminated())).toBe(true);
    expect(isTransientNetworkError(undiciBodyTerminatedBare())).toBe(true);
  });

  it("does NOT match 'terminated' as a substring of an unrelated word", () => {
    expect(isTransientNetworkError(new Error("subterminated nonsense"))).toBe(false);
  });

  it("retries when res.json() throws, not just when fetch() throws", async () => {
    let calls = 0;
    const fetchFn = async () => {
      calls++;
      const ok = calls >= 3;
      return {
        status: 200, ok: true, headers: { get: () => null },
        json: async () => { if (!ok) throw undiciBodyTerminated(); return { data: [] }; },
      } as any;
    };
    const c = new PptClient("k", new CreditBudget(100), fetchFn, noSleep, new MinuteRateLimiter(45, () => 0));
    await expect(c.getSetCards("Base")).resolves.toEqual([]);
    expect(calls).toBe(3);
  });

  it("exhausts the same ladder on a persistently terminated body (6 attempts)", async () => {
    let calls = 0;
    const fetchFn = async () => {
      calls++;
      return {
        status: 200, ok: true, headers: { get: () => null },
        json: async () => { throw undiciBodyTerminated(); },
      } as any;
    };
    const c = new PptClient("k", new CreditBudget(100), fetchFn, noSleep, new MinuteRateLimiter(45, () => 0));
    await expect(c.getSetCards("Base")).rejects.toThrow(/terminated/);
    expect(calls).toBe(6);
  });

  it("covers every body-reading endpoint, not just getSetCards", async () => {
    const mk = () => {
      let calls = 0;
      const fetchFn = async () => {
        calls++;
        const ok = calls >= 2;
        return {
          status: 200, ok: true, headers: { get: () => null },
          json: async () => { if (!ok) throw undiciBodyTerminated(); return { data: [] }; },
        } as any;
      };
      return { fetchFn, calls: () => calls };
    };
    for (const call of [
      (c: PptClient) => c.getSetPrices("Base"),
      (c: PptClient) => c.getSetHistory("Base", 1),
      (c: PptClient) => c.getSetEnrichment("Base"),
      (c: PptClient) => c.getPopulation([123]),
      (c: PptClient) => c.getAllSets(),
    ]) {
      const m = mk();
      // Roomy ceiling on purpose: the history/enrichment/population endpoints reserve the
      // worst-case cost of 30 each, and with a frozen clock a 45/min window would block forever
      // on the retry's second reservation rather than exercise the retry.
      const c = new PptClient("k", new CreditBudget(1000), m.fetchFn, noSleep, new MinuteRateLimiter(1000, () => 0));
      await call(c);
      expect(m.calls()).toBe(2);
    }
  });

  it("never reads the body of a 429 — a rate-limit signal must not spend a network retry", async () => {
    let jsonReads = 0;
    const script = ["429", "ok"];
    let i = 0;
    const fetchFn = async () => {
      const step = script[i++];
      if (step === "429") {
        return { status: 429, ok: false, headers: { get: () => null }, json: async () => { jsonReads++; return {}; } } as any;
      }
      return res({ data: [] }) as any;
    };
    const c = new PptClient("k", new CreditBudget(100), fetchFn, noSleep, new MinuteRateLimiter(45, () => 0));
    await expect(c.getSetCards("Base")).resolves.toEqual([]);
    expect(jsonReads).toBe(0);
  });
});
