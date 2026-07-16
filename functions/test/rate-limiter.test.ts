import { describe, it, expect } from "vitest";
import { MinuteRateLimiter } from "../src/upstream/rate-limiter";

/** Deterministic clock: sleeping advances virtual time; records sleep durations. */
function fakeClock(start = 0) {
  let t = start;
  const sleeps: number[] = [];
  return {
    now: () => t,
    sleep: async (ms: number) => { t += ms; sleeps.push(ms); },
    sleeps,
  };
}

describe("MinuteRateLimiter", () => {
  it("admits costs immediately while the trailing window has room", async () => {
    const c = fakeClock();
    const rl = new MinuteRateLimiter(45, c.now);
    for (let i = 0; i < 15; i++) await rl.acquire(3, c.sleep); // 15*3 = 45 exactly, all at t=0
    expect(c.sleeps).toEqual([]);
  });

  it("blocks a reservation that would exceed 45 until old entries age out", async () => {
    const c = fakeClock();
    const rl = new MinuteRateLimiter(45, c.now);
    for (let i = 0; i < 15; i++) await rl.acquire(3, c.sleep); // fills to 45 at t=0
    await rl.acquire(3, c.sleep);                              // must wait a full window
    expect(c.sleeps).toEqual([60_000]);
  });

  it("caps a 30-cost reservation to at most once per window alongside a 15-cost one", async () => {
    const c = fakeClock();
    const rl = new MinuteRateLimiter(45, c.now);
    await rl.acquire(30, c.sleep);         // 30 at t=0
    await rl.acquire(15, c.sleep);         // 45 total at t=0 → still fits
    expect(c.sleeps).toEqual([]);
    await rl.acquire(30, c.sleep);         // 75 > 45 → wait for t=0 entries to drop
    expect(c.sleeps).toEqual([60_000]);
  });

  it("throws if a single cost exceeds the max", async () => {
    const c = fakeClock();
    const rl = new MinuteRateLimiter(45, c.now);
    await expect(rl.acquire(46, c.sleep)).rejects.toThrow(/exceeds max/);
  });
});
