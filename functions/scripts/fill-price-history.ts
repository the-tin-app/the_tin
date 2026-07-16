/**
 * Fill price_history for the whole catalog from PPT. LIVE — needs PPT_API_KEY. Paced (<=45/min) and
 * RESUMABLE: completed sets are recorded in <db>.sweep-progress.json; re-run on later days until the
 * sweep completes, then it publishes a new catalog version. Operator step — see the runbook.
 *
 * Usage: PPT_API_KEY=$PPT_PAID npx tsx scripts/fill-price-history.ts <catalog.sqlite> <version> [outDir=.seed-output]
 */
import Database from "better-sqlite3";
import { join } from "node:path";
import { writeFileSync, mkdirSync } from "node:fs";
import { PptClient, CreditBudget, parseCreditBudget, CreditBudgetExceeded } from "../src/upstream/ppt";
import { resolvePptSetName } from "../src/pipeline/ppt-setmap";
import { runHistorySweep, loadDoneSets, appendDoneSet, SweepSet } from "../src/pipeline/history-sweep-core";
import { publishCatalog, StoragePort } from "../src/pipeline/publish";

class LocalStorage implements StoragePort {
  constructor(private outDir: string) {}
  async save(path: string, data: Buffer): Promise<void> {
    const full = join(this.outDir, path);
    mkdirSync(join(full, ".."), { recursive: true });
    writeFileSync(full, data);
  }
}

async function main() {
  const key = process.env.PPT_API_KEY;
  if (!key) throw new Error("PPT_API_KEY not set — export the paid key ($PPT_PAID)");
  const dbPath = process.argv[2];
  const version = Number(process.argv[3]);
  const outDir = process.argv[4] ?? join(__dirname, "../.seed-output");
  if (!dbPath || !Number.isInteger(version)) throw new Error("usage: fill-price-history.ts <catalog.sqlite> <version> [outDir]");

  const db = new Database(dbPath);
  const client = new PptClient(key, new CreditBudget(parseCreditBudget(process.env.PPT_DAILY_CREDIT_BUDGET, 20000)));

  // Resolve every catalog set to its PPT name (skip unmapped — same policy as enrichment).
  const pptSets = await client.getAllSets();
  const ourSets = db.prepare("SELECT id, name, release_date AS releaseDate FROM set_info ORDER BY release_date DESC")
    .all() as { id: string; name: string; releaseDate: string | null }[];
  const sets: SweepSet[] = [];
  let unmapped = 0;
  for (const s of ourSets) {
    const ppt = resolvePptSetName({ id: s.id, name: s.name, releaseDate: s.releaseDate }, pptSets);
    if (!ppt) { unmapped++; continue; }
    sets.push({ setId: s.id, pptName: ppt.name });
  }

  const progressPath = `${dbPath}.sweep-progress.json`;
  const doneSets = loadDoneSets(progressPath);
  const progress = { doneSets, markDone: (id: string) => { doneSets.add(id); appendDoneSet(progressPath, id); } };

  const isStopError = (e: unknown) =>
    e instanceof CreditBudgetExceeded || /PPT (429|403)/.test((e as Error)?.message ?? "");

  console.log(`[history] ${sets.length} mapped sets (${unmapped} unmapped) · ${doneSets.size} already done · pacing <=45/min`);
  const summary = await runHistorySweep(db, client, sets, progress, isStopError);
  console.log(`[history] +${summary.setsDone} sets · ${summary.rowsWritten} rows${summary.stoppedEarly ? ` · STOPPED (${summary.stopReason})` : ""}`);

  if (summary.stoppedEarly) {
    console.log(`[history] sweep stopped early (${summary.stopReason}) — NOT publishing a partial sweep. Re-run after credits reset.`);
    return;
  }

  const remaining = sets.filter((s) => !doneSets.has(s.setId)).length;
  if (remaining > 0) {
    console.log(`[history] ${remaining} sets remain — re-run tomorrow (credits reset midnight UTC). NOT publishing a partial sweep.`);
    return;
  }
  console.log(`[history] sweep complete — publishing catalog v${version} to ${outDir}/catalog/ …`);
  const manifest = await publishCatalog(dbPath, version, new LocalStorage(outDir), new Date());
  console.log(`[history] published v${manifest.version} · ${manifest.sizeBytes.toLocaleString()} gz bytes · sha256 ${manifest.sha256}`);
  console.log(`[history] upload with: gsutil cp ${outDir}/catalog/{manifest.json,${manifest.path.split("/").pop()}} gs://${process.env.FIREBASE_STORAGE_BUCKET ?? "<your-bucket>"}/catalog/`);
}

main().catch((e) => { console.error(e); process.exit(1); });
