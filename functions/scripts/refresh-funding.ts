/**
 * Refresh the community-funding block + supporters list in the catalog manifest. Run by the
 * nightly rebuild cron right AFTER build-catalog/publish — publish-tiers rewrites manifest.json
 * from scratch each night, so both blocks are re-merged here every run rather than persisting.
 *
 * iOS reads `manifest.funding` and `manifest.supporters` (see FundingModel.swift) as display-only
 * — no gate, no state machine, and nothing in the app is unlocked by either.
 *
 * Usage: npx tsx scripts/refresh-funding.ts <catalogDir> [sponsorsLogin] [goalCents=15000]
 *   env: GITHUB_TOKEN (required for the meter — org-admin PAT with `read:org`),
 *        GITHUB_SPONSORS_LOGIN, FUNDING_GOAL_CENTS
 *
 * Supporters come from a hand-curated `supporters.json` sitting in <catalogDir>, NOT from the
 * API: every sponsor welcome message promises anonymity, so listing must be an explicit act.
 * Absence from the file IS the anonymity mechanism — there is no "hidden" flag to forget to set.
 */
import { readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { join } from "node:path";
import { fetchSponsorsStats, FetchLike } from "../src/upstream/githubSponsors";

export interface FundingSnapshot {
  fundedPct: number;
  monthlyGoalCents: number;
  raisedCents: number;
  updatedAt: string;
}

export interface Supporter {
  name: string;
  tier?: string;
  url?: string;
}

export function computeSnapshot(raisedCents: number, goalCents: number, now: Date): FundingSnapshot {
  return {
    fundedPct: goalCents > 0 ? raisedCents / goalCents : 0, // iOS clamps to 0…1 for display
    monthlyGoalCents: goalCents,
    raisedCents,
    updatedAt: now.toISOString(),
  };
}

/**
 * Read + validate the hand-maintained supporters file. Hand-edited JSON is a trust boundary: a
 * malformed entry that reached the manifest would ship to every device, so entries without a
 * usable name are dropped and non-https links are stripped rather than opened on someone's phone.
 * Returns [] when the file is missing (the normal state — nobody is listed yet).
 */
export function readSupporters(catalogDir: string): Supporter[] {
  const path = join(catalogDir, "supporters.json");
  if (!existsSync(path)) return [];
  const parsed = JSON.parse(readFileSync(path, "utf8")) as { supporters?: unknown };
  const raw = Array.isArray(parsed.supporters) ? parsed.supporters : [];
  return raw.flatMap((entry) => {
    if (typeof entry !== "object" || entry === null) return [];
    const { name, tier, url } = entry as Record<string, unknown>;
    if (typeof name !== "string" || !name.trim()) return [];
    const s: Supporter = { name: name.trim() };
    if (typeof tier === "string" && tier.trim()) s.tier = tier.trim();
    if (typeof url === "string" && url.startsWith("https://")) s.url = url;
    return [s];
  });
}

// Merge blocks into manifest.json atomically (temp file + rename) so a concurrent /catalog read
// never sees a half-written file.
// ponytail: no lock vs the publish step — this runs AFTER publish in the same nightly chain, so
// they never write concurrently. Add one only if this ever moves to its own schedule.
export function writeManifestBlocks(
  catalogDir: string, blocks: { funding?: FundingSnapshot; supporters?: Supporter[] },
): void {
  const manifestPath = join(catalogDir, "manifest.json");
  const manifest = existsSync(manifestPath)
    ? (JSON.parse(readFileSync(manifestPath, "utf8")) as Record<string, unknown>)
    : {};
  if (blocks.funding) manifest.funding = blocks.funding;
  if (blocks.supporters) manifest.supporters = blocks.supporters;
  const tmp = `${manifestPath}.tmp`;
  writeFileSync(tmp, JSON.stringify(manifest));
  renameSync(tmp, manifestPath);
}

export async function refreshFunding(opts: {
  catalogDir: string; login: string; token: string; goalCents: number; now: Date; fetchFn: FetchLike;
}): Promise<FundingSnapshot> {
  const stats = await fetchSponsorsStats(opts.login, opts.token, opts.fetchFn);
  // The page's own goal wins when it has one, so raising it on GitHub moves the meter without a
  // pipeline change; the CLI/env value is only the fallback.
  const snapshot = computeSnapshot(stats.monthlyIncomeCents, stats.goalCents ?? opts.goalCents, opts.now);
  writeManifestBlocks(opts.catalogDir, { funding: snapshot });
  return snapshot;
}

async function main() {
  const catalogDir = process.argv[2];
  if (!catalogDir) {
    console.error("usage: refresh-funding.ts <catalogDir> [sponsorsLogin] [goalCents=15000]");
    process.exit(1);
  }

  // Supporters are independent of the API — publish them even when the meter can't refresh, so a
  // missing token never silently drops names that are already promised to be shown.
  try {
    const supporters = readSupporters(catalogDir);
    writeManifestBlocks(catalogDir, { supporters });
    console.log(`supporters refreshed: ${supporters.length} listed`);
  } catch (e) {
    console.error("supporters refresh failed (keeping manifest as-is):", (e as Error).message);
  }

  const login = process.argv[3] || process.env.GITHUB_SPONSORS_LOGIN;
  const token = process.env.GITHUB_TOKEN;
  if (!login || !token) {
    console.log("no GitHub Sponsors login/token configured (GITHUB_SPONSORS_LOGIN + GITHUB_TOKEN) — skipping funding refresh");
    return;
  }
  const goalCents = Number(process.argv[4] ?? process.env.FUNDING_GOAL_CENTS ?? 15000);
  const s = await refreshFunding({ catalogDir, login, token, goalCents, now: new Date(), fetchFn: fetch as unknown as FetchLike });
  console.log(`funding refreshed: ${Math.round(s.fundedPct * 100)}% funded ($${s.raisedCents / 100} of $${s.monthlyGoalCents / 100}/mo)`);
}

// CLI only — importing for tests must not run main(). A failure here (e.g. GitHub outage) exits 1
// and leaves the prior funding block untouched; the build/publish that already ran is unaffected
// and the next night's run self-heals.
if (require.main === module) {
  main().catch((e) => { console.error("funding refresh failed:", (e as Error).message); process.exit(1); });
}
