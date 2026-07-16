import { describe, it, expect } from "vitest";
import { createChallengeStore } from "../src/challenges";

describe("challenge store", () => {
  it("issues a nonce that can be consumed exactly once", () => {
    const store = createChallengeStore(60);
    const nonce = store.issue();
    expect(store.consume(nonce)).toBe(true);
    expect(store.consume(nonce)).toBe(false);
  });

  it("rejects an unknown nonce", () => {
    const store = createChallengeStore(60);
    expect(store.consume("never-issued")).toBe(false);
  });

  it("rejects an expired nonce", () => {
    const realNow = Date.now;
    Date.now = () => new Date("2026-01-01T00:00:00Z").getTime();
    const store = createChallengeStore(10);
    const nonce = store.issue();
    Date.now = () => new Date("2026-01-01T00:00:11Z").getTime();
    expect(store.consume(nonce)).toBe(false);
    Date.now = realNow;
  });

  it("sweeps expired nonces on issue() without breaking expiry semantics", () => {
    // Not independently observable through the public API (the Map isn't exposed),
    // so this just re-confirms correctness holds across many issue/expire cycles —
    // i.e. the opportunistic sweep in issue() doesn't disturb consume() behavior.
    const realNow = Date.now;
    let now = new Date("2026-01-01T00:00:00Z").getTime();
    Date.now = () => now;
    const store = createChallengeStore(10);

    const staleNonces: string[] = [];
    for (let i = 0; i < 50; i++) {
      staleNonces.push(store.issue());
      now += 11_000; // advance past the 10s TTL each time, forcing everything stale
    }

    const freshNonce = store.issue();

    for (const stale of staleNonces) {
      expect(store.consume(stale)).toBe(false);
    }
    expect(store.consume(freshNonce)).toBe(true);

    Date.now = realNow;
  });
});
