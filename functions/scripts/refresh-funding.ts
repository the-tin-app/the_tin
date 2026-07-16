/**
 * Refresh the community-funding block in the catalog manifest. Run by the nightly rebuild cron
 * right AFTER build-catalog/publish — the same 24h cadence that re-downloads the PPT CSV and
 * rebuilds the DBs. No webhook: we re-fetch this month's Open Collective total and merge it into
 * the manifest.json the catalog-server serves.
 *
 * iOS reads `manifest.funding` (see FundingModel.swift) as display-only (no gate, no state
 * machine), so we only write the progress fields.
 *
 * Usage: npx tsx scripts/refresh-funding.ts <catalogDir> [ocSlug] [goalCents=15000]
 */
import { readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { join } from "node:path";
import { fetchOcStats, FetchLike } from "../src/upstream/openCollective";

export interface FundingSnapshot {
  fundedPct: number;
  monthlyGoalCents: number;
  raisedCents: number;
  updatedAt: string;
}

// First instant of the current UTC month, e.g. "2026-07-01T00:00:00Z" — the dateFrom the OC
// query sums donations from, so raised resets at each month boundary.
export function monthStartIso(now: Date): string {
  return `${now.toISOString().slice(0, 7)}-01T00:00:00Z`;
}

export function computeSnapshot(raisedCents: number, goalCents: number, now: Date): FundingSnapshot {
  return {
    fundedPct: goalCents > 0 ? raisedCents / goalCents : 0, // iOS clamps to 0…1 for display
    monthlyGoalCents: goalCents,
    raisedCents,
    updatedAt: now.toISOString(),
  };
}

// Merge the funding block into manifest.json atomically (temp file + rename) so a concurrent
// /catalog read never sees a half-written file.
// ponytail: no lock vs the publish step — this runs AFTER publish in the same nightly chain, so
// they never write concurrently. Add one only if funding ever moves to its own schedule.
export function writeFundingBlock(catalogDir: string, funding: FundingSnapshot): void {
  const manifestPath = join(catalogDir, "manifest.json");
  const manifest = existsSync(manifestPath)
    ? (JSON.parse(readFileSync(manifestPath, "utf8")) as Record<string, unknown>)
    : {};
  manifest.funding = funding;
  const tmp = `${manifestPath}.tmp`;
  writeFileSync(tmp, JSON.stringify(manifest));
  renameSync(tmp, manifestPath);
}

export async function refreshFunding(opts: {
  catalogDir: string; ocSlug: string; goalCents: number; now: Date; fetchFn: FetchLike;
}): Promise<FundingSnapshot> {
  const { raisedThisMonthCents } = await fetchOcStats(opts.ocSlug, monthStartIso(opts.now), opts.fetchFn);
  const snapshot = computeSnapshot(raisedThisMonthCents, opts.goalCents, opts.now);
  writeFundingBlock(opts.catalogDir, snapshot);
  return snapshot;
}

async function main() {
  const catalogDir = process.argv[2];
  if (!catalogDir) {
    console.error("usage: refresh-funding.ts <catalogDir> [ocSlug] [goalCents=15000]");
    process.exit(1);
  }
  const ocSlug = process.argv[3] || process.env.OC_SLUG;
  if (!ocSlug) {
    console.log("no Open Collective slug configured (OC_SLUG or argv) — skipping funding refresh");
    return;
  }
  const goalCents = Number(process.argv[4] ?? process.env.FUNDING_GOAL_CENTS ?? 15000);
  const s = await refreshFunding({ catalogDir, ocSlug, goalCents, now: new Date(), fetchFn: fetch as unknown as FetchLike });
  console.log(`funding refreshed: ${Math.round(s.fundedPct * 100)}% funded ($${s.raisedCents / 100} of $${s.monthlyGoalCents / 100}/mo)`);
}

// CLI only — importing for tests must not run main(). A failure here (e.g. OC outage) exits 1 and
// leaves the prior funding block untouched; the build/publish that already ran is unaffected and
// the next night's run self-heals.
if (require.main === module) {
  main().catch((e) => { console.error("funding refresh failed:", (e as Error).message); process.exit(1); });
}
