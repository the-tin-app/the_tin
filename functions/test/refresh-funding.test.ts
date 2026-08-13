import { describe, it, expect } from "vitest";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { computeSnapshot, readSupporters, writeManifestBlocks, refreshFunding } from "../scripts/refresh-funding";
import { FetchLike } from "../src/upstream/githubSponsors";

const tmp = () => mkdtempSync(join(tmpdir(), "funding-"));
const manifestIn = (dir: string) => JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));

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

describe("readSupporters", () => {
  const write = (dir: string, body: unknown) =>
    writeFileSync(join(dir, "supporters.json"), JSON.stringify(body));

  it("returns [] when nobody is listed yet (no file)", () => {
    expect(readSupporters(tmp())).toEqual([]);
  });

  it("reads name, tier and link", () => {
    const dir = tmp();
    write(dir, { supporters: [{ name: "Ada", tier: "secret-rare", url: "https://example.com" }] });
    expect(readSupporters(dir)).toEqual([{ name: "Ada", tier: "secret-rare", url: "https://example.com" }]);
  });

  it("drops entries with no usable name instead of shipping a blank row", () => {
    const dir = tmp();
    write(dir, { supporters: [{ name: "  " }, { tier: "holo" }, "Ada", null, { name: "Grace" }] });
    expect(readSupporters(dir)).toEqual([{ name: "Grace" }]);
  });

  it("strips non-https links rather than sending one to a phone", () => {
    const dir = tmp();
    write(dir, { supporters: [{ name: "Ada", url: "javascript:alert(1)" }, { name: "Bob", url: "http://x.test" }] });
    expect(readSupporters(dir)).toEqual([{ name: "Ada" }, { name: "Bob" }]);
  });

  it("tolerates a file whose supporters key is missing or not an array", () => {
    const dir = tmp();
    write(dir, { note: "placeholder" });
    expect(readSupporters(dir)).toEqual([]);
  });
});

describe("writeManifestBlocks", () => {
  it("merges funding into an existing manifest without clobbering catalog fields", () => {
    const dir = tmp();
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({ version: 7, core: { path: "core-v7.sqlite.gz" } }));
    const snap = computeSnapshot(6300, 15000, new Date("2026-07-12T00:00:00Z"));
    writeManifestBlocks(dir, { funding: snap });
    const m = manifestIn(dir);
    expect(m.version).toBe(7);
    expect(m.core.path).toBe("core-v7.sqlite.gz");
    expect(m.funding).toEqual(snap);
  });

  it("writes supporters without disturbing an existing funding block", () => {
    const dir = tmp();
    const snap = computeSnapshot(6300, 15000, new Date("2026-07-12T00:00:00Z"));
    writeManifestBlocks(dir, { funding: snap });
    writeManifestBlocks(dir, { supporters: [{ name: "Ada" }] });
    const m = manifestIn(dir);
    expect(m.funding).toEqual(snap);
    expect(m.supporters).toEqual([{ name: "Ada" }]);
  });

  it("publishes an empty supporters list — an emptied file must clear the screen", () => {
    const dir = tmp();
    writeManifestBlocks(dir, { supporters: [{ name: "Ada" }] });
    writeManifestBlocks(dir, { supporters: [] });
    expect(manifestIn(dir).supporters).toEqual([]);
  });

  it("creates a manifest when none exists yet", () => {
    const dir = tmp();
    const snap = computeSnapshot(0, 15000, new Date("2026-07-12T00:00:00Z"));
    writeManifestBlocks(dir, { funding: snap });
    expect(manifestIn(dir).funding).toEqual(snap);
  });
});

describe("refreshFunding", () => {
  const respond = (org: unknown): FetchLike => async () => ({
    ok: true, status: 200, json: async () => ({ data: { repositoryOwner: org } }),
  });

  it("fetches GitHub, computes, and writes the block", async () => {
    const dir = tmp();
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({ version: 7 }));
    const snap = await refreshFunding({
      catalogDir: dir, login: "the-tin-app", token: "tok", goalCents: 15000,
      now: new Date("2026-07-12T00:00:00Z"),
      fetchFn: respond({ monthlyEstimatedSponsorsIncomeInCents: 7500, sponsorsListing: null }),
    });
    expect(snap.raisedCents).toBe(7500);
    expect(snap.fundedPct).toBeCloseTo(0.5);
    expect(manifestIn(dir).funding.raisedCents).toBe(7500);
    expect(manifestIn(dir).version).toBe(7);
  });

  it("prefers the goal configured on the Sponsors page over the CLI fallback", async () => {
    const snap = await refreshFunding({
      catalogDir: tmp(), login: "the-tin-app", token: "tok", goalCents: 15000,
      now: new Date("2026-07-12T00:00:00Z"),
      fetchFn: respond({
        monthlyEstimatedSponsorsIncomeInCents: 25000,
        sponsorsListing: { activeGoal: { kind: "MONTHLY_SPONSORSHIP_AMOUNT", targetValue: 500 } },
      }),
    });
    expect(snap.monthlyGoalCents).toBe(50000);
    expect(snap.fundedPct).toBeCloseTo(0.5);
  });
});
