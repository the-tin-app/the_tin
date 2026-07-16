import { describe, it, expect } from "vitest";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { monthStartIso, computeSnapshot, writeFundingBlock, refreshFunding } from "../scripts/refresh-funding";
import { FetchLike } from "../src/upstream/openCollective";

describe("monthStartIso", () => {
  it("returns the first instant of the current UTC month", () => {
    expect(monthStartIso(new Date("2026-07-12T18:19:00Z"))).toBe("2026-07-01T00:00:00Z");
  });
});

describe("computeSnapshot", () => {
  it("computes fundedPct as raised/goal", () => {
    const s = computeSnapshot(6300, 15000, new Date("2026-07-12T00:00:00Z"));
    expect(s.fundedPct).toBeCloseTo(0.42);
    expect(s.monthlyGoalCents).toBe(15000);
    expect(s.raisedCents).toBe(6300);
    expect(s.updatedAt).toBe("2026-07-12T00:00:00.000Z");
  });
  it("avoids divide-by-zero when goal is 0", () => {
    expect(computeSnapshot(500, 0, new Date("2026-07-12T00:00:00Z")).fundedPct).toBe(0);
  });
});

describe("writeFundingBlock", () => {
  it("merges funding into an existing manifest without clobbering catalog fields", () => {
    const dir = mkdtempSync(join(tmpdir(), "funding-"));
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({ version: 7, core: { path: "core-v7.sqlite.gz" } }));
    const snap = computeSnapshot(6300, 15000, new Date("2026-07-12T00:00:00Z"));
    writeFundingBlock(dir, snap);
    const m = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
    expect(m.version).toBe(7);
    expect(m.core.path).toBe("core-v7.sqlite.gz");
    expect(m.funding).toEqual(snap);
  });

  it("creates a manifest when none exists yet", () => {
    const dir = mkdtempSync(join(tmpdir(), "funding-"));
    const snap = computeSnapshot(0, 15000, new Date("2026-07-12T00:00:00Z"));
    writeFundingBlock(dir, snap);
    expect(JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8")).funding).toEqual(snap);
  });
});

describe("refreshFunding", () => {
  it("fetches OC, computes, and writes the block", async () => {
    const dir = mkdtempSync(join(tmpdir(), "funding-"));
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({ version: 7 }));
    const fetchFn: FetchLike = async () => ({
      ok: true,
      status: 200,
      json: async () => ({ data: { account: { stats: { totalAmountReceived: { valueInCents: 7500 }, balance: { valueInCents: 20000 } } } } }),
    });
    const snap = await refreshFunding({ catalogDir: dir, ocSlug: "the-tin", goalCents: 15000, now: new Date("2026-07-12T00:00:00Z"), fetchFn });
    expect(snap.raisedCents).toBe(7500);
    expect(snap.fundedPct).toBeCloseTo(0.5);
    expect(JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8")).funding.raisedCents).toBe(7500);
  });
});
