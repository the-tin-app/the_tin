// functions/scripts/fill-overnight.ts
/**
 * Unified overnight PPT enrichment sweep → catalog v5. LIVE — needs PPT_API_KEY ($PPT_PAID).
 * Resumable (sidecar <db>.sweep-overnight.json), interruptible, <=45/min, never retries 429/403.
 * Preflight probe decides graded-history mode + population entitlement before the full sweep.
 *
 * Usage: PPT_API_KEY=$PPT_PAID npx tsx scripts/fill-overnight.ts <catalog.sqlite> <version> [outDir]
 *   --done-check : exit 0 iff all enabled units already done (for the auto-resume wrapper), no API calls.
 */
import Database from "better-sqlite3";
import { join } from "node:path";
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { PptClient, CreditBudget, parseCreditBudget, CreditBudgetExceeded, isTransientNetworkError } from "../src/upstream/ppt";
import { resolvePptSetName } from "../src/pipeline/ppt-setmap";
import { runProbe, ProbeResult } from "../src/pipeline/overnight-probe";
import { runOvernightSweep, OvernightSet, OvernightLedger } from "../src/pipeline/overnight-sweep-core";
import { publishCatalog, StoragePort } from "../src/pipeline/publish";
import { isRateLimitStop, haltGate } from "../src/pipeline/overnight-halt";

class LocalStorage implements StoragePort {
  constructor(private outDir: string) {}
  async save(path: string, data: Buffer) { const full = join(this.outDir, path); mkdirSync(join(full, ".."), { recursive: true }); writeFileSync(full, data); }
}

interface Sidecar { probe?: ProbeResult; setsDone: string[]; popBatchesDone: string[]; updatedAt?: string; mappedSetCount?: number; haltedForRateLimit?: string; }
function loadSidecar(p: string): Sidecar {
  if (!existsSync(p)) return { setsDone: [], popBatchesDone: [] };
  try { const j = JSON.parse(readFileSync(p, "utf8")); return { probe: j.probe, setsDone: j.setsDone ?? [], popBatchesDone: j.popBatchesDone ?? [], mappedSetCount: j.mappedSetCount, haltedForRateLimit: j.haltedForRateLimit }; }
  catch { return { setsDone: [], popBatchesDone: [] }; }
}
function saveSidecar(p: string, s: Sidecar) { writeFileSync(p, JSON.stringify({ ...s, updatedAt: new Date().toISOString() })); }

function buildSets(db: Database.Database, pptSets: { name: string; slug: string; series: string; releaseDate: string | null }[]): { sets: OvernightSet[]; unmapped: number } {
  const ourSets = db.prepare("SELECT id, name, release_date AS releaseDate FROM set_info ORDER BY release_date DESC").all() as { id: string; name: string; releaseDate: string | null }[];
  const sets: OvernightSet[] = []; let unmapped = 0;
  for (const s of ourSets) {
    const ppt = resolvePptSetName({ id: s.id, name: s.name, releaseDate: s.releaseDate }, pptSets as any);
    if (!ppt) { unmapped++; continue; }
    sets.push({ setId: s.id, pptName: ppt.name });
  }
  return { sets, unmapped };
}

async function main() {
  const key = process.env.PPT_API_KEY;
  const dbPath = process.argv[2];
  const version = Number(process.argv[3]);
  const outDir = process.argv[4]?.startsWith("--") ? undefined : process.argv[4];
  const doneCheck = process.argv.includes("--done-check");
  if (!dbPath || !Number.isInteger(version)) throw new Error("usage: fill-overnight.ts <catalog.sqlite> <version> [outDir] [--done-check]");
  const resolvedOut = outDir ?? join(__dirname, "../.seed-output");

  if (!existsSync(dbPath)) { console.error(`[overnight] no such catalog DB: ${dbPath}`); process.exit(1); }

  const db = new Database(dbPath);
  const sidecarPath = `${dbPath}.sweep-overnight.json`;
  const sc = loadSidecar(sidecarPath);

  // --done-check: all sets done AND (population disabled OR all pop batches done). No API calls.
  if (doneCheck) {
    // A halted sweep (prior 429/403) reports "done" so the auto-resume `until` wrapper STOPS
    // looping instead of re-firing the PPT API ~5s later into the ban window.
    if (sc.haltedForRateLimit) process.exit(0);
    if (!sc.probe) process.exit(1);
    const idCount = (db.prepare("SELECT COUNT(DISTINCT tcgplayer_id) AS n FROM card WHERE tcgplayer_id IS NOT NULL").get() as any).n as number;
    const popBatches = sc.probe.populationEnabled ? Math.ceil(idCount / 50) : 0;
    if (sc.mappedSetCount == null) process.exit(1);
    const setCount = sc.mappedSetCount;
    const done = sc.setsDone.length >= setCount && sc.popBatchesDone.length >= popBatches;
    process.exit(done ? 0 : 1);
  }

  const gate = haltGate(!!sc.haltedForRateLimit, process.env.PPT_CLEAR_RATELIMIT_HALT);
  if (gate === "refuse") {
    console.error(`[overnight] HALTED after a prior rate-limit/ban stop at ${sc.haltedForRateLimit}. Refusing to call the PPT API. Wait out the ban window, then re-run with PPT_CLEAR_RATELIMIT_HALT=1 to resume.`);
    process.exit(2);
  }
  if (gate === "clear") {
    delete sc.haltedForRateLimit;
    saveSidecar(sidecarPath, sc);
    console.log("[overnight] rate-limit halt cleared by operator — resuming.");
  }

  if (!key) throw new Error("PPT_API_KEY not set — export the paid key ($PPT_PAID)");
  const client = new PptClient(key, new CreditBudget(parseCreditBudget(process.env.PPT_CREDIT_BUDGET, 130000)));
  let pptSets;
  try {
    pptSets = await client.getAllSets();
  } catch (e) {
    if (isRateLimitStop((e as Error)?.message)) {
      sc.haltedForRateLimit = new Date().toISOString();
      saveSidecar(sidecarPath, sc);
      console.error(`[overnight] RATE-LIMIT STOP on getAllSets (${(e as Error).message}) — halted, auto-resume disabled. Wait out the ban window, then re-run with PPT_CLEAR_RATELIMIT_HALT=1.`);
      process.exit(2);
    }
    throw e;
  }
  // eslint-disable-next-line prefer-const -- `sets` is reassigned by SWEEP_SET_LIMIT below
  let { sets, unmapped } = buildSets(db, pptSets);
  // SWEEP_SET_LIMIT=N runs only the first N mapped sets — a bounded, cheap validation run (won't
  // reach the all-sets-done publish gate, which is the point: inspect condition rows, don't ship).
  const setLimit = Number(process.env.SWEEP_SET_LIMIT);
  if (Number.isInteger(setLimit) && setLimit > 0) {
    console.log(`[overnight] SWEEP_SET_LIMIT=${setLimit} — bounded test run (will NOT publish)`);
    sets = sets.slice(0, setLimit);
  }
  sc.mappedSetCount = sets.length;
  saveSidecar(sidecarPath, sc);

  // Preflight probe once; persist the decision so a resume never re-probes.
  if (!sc.probe) {
    const sample = sets[0];
    if (!sample) throw new Error("no mapped set to probe with");
    const sampleTid = (db.prepare("SELECT tcgplayer_id AS t FROM card WHERE tcgplayer_id IS NOT NULL LIMIT 1").get() as any)?.t ?? null;
    if (sampleTid == null) {
      console.log("[overnight] no tcgplayer_id found in catalog — skipping population entitlement probe.");
    }
    try {
      sc.probe = await runProbe(client as any, sample.pptName, sampleTid, new Date().toISOString());
    } catch (e) {
      if (isRateLimitStop((e as Error)?.message)) {
        sc.haltedForRateLimit = new Date().toISOString();
        saveSidecar(sidecarPath, sc);
        console.error(`[overnight] RATE-LIMIT STOP on probe (${(e as Error).message}) — halted, auto-resume disabled. Wait out the ban window, then re-run with PPT_CLEAR_RATELIMIT_HALT=1.`);
        process.exit(2);
      }
      throw e;
    }
    saveSidecar(sidecarPath, sc);
    console.log(`[overnight] probe: minuteLimit=${sc.probe.minuteLimit} purchasedRemaining=${sc.probe.purchasedRemaining} gradedHistory=${sc.probe.gradedHistoryMode} population=${sc.probe.populationEnabled ? "ENABLED" : "SKIPPED (403)"}`);
  } else {
    console.log(`[overnight] resuming — graded=${sc.probe.gradedHistoryMode} population=${sc.probe.populationEnabled}`);
  }

  const setsDone = new Set(sc.setsDone), popBatchesDone = new Set(sc.popBatchesDone);
  const ledger: OvernightLedger = {
    setsDone, popBatchesDone,
    markSet: (id) => { setsDone.add(id); sc.setsDone = [...setsDone]; saveSidecar(sidecarPath, sc); },
    markPopBatch: (k) => { popBatchesDone.add(k); sc.popBatchesDone = [...popBatchesDone]; saveSidecar(sidecarPath, sc); },
  };
  // Network errors land here only after PptClient's in-request retry ladder (~5.5min) is
  // exhausted — i.e. a real outage. Treat as a resumable stop (ledger keeps per-set progress),
  // NOT a crash: the entrypoint must still publish the base catalog and re-enrich tomorrow.
  const isStopError = (e: unknown) =>
    e instanceof CreditBudgetExceeded || /PPT (429|403)/.test((e as Error)?.message ?? "") || isTransientNetworkError(e);
  const asOf = new Date().toISOString().slice(0, 10);

  const paceMax = Number(process.env.PPT_MINUTE_LIMIT) || 45;
  console.log(`[overnight] ${sets.length} mapped sets (${unmapped} unmapped) · ${setsDone.size} sets done · pacing <=${paceMax}/min`);
  // A bounded test run skips population Phase B (it fans out over ALL tcgplayer_ids regardless of
  // the set limit, and population comes from the bulk export anyway).
  const bounded = Number.isInteger(setLimit) && setLimit > 0;
  const summary = await runOvernightSweep(db as any, client as any, sets, ledger,
    { populationEnabled: bounded ? false : sc.probe.populationEnabled, asOf }, isStopError);
  console.log(`[overnight] +${summary.setsDone} sets · ${summary.historyRows} history · ${summary.gradedRows} graded · ${summary.popRows} pop${summary.stoppedEarly ? ` · STOPPED (${summary.stopReason})` : ""}`);

  if (summary.stoppedEarly) {
    if (isRateLimitStop(summary.stopReason)) {
      sc.haltedForRateLimit = new Date().toISOString();
      saveSidecar(sidecarPath, sc);
      console.log(`[overnight] RATE-LIMIT STOP (${summary.stopReason}) — auto-resume disabled. Wait out the ban window, then re-run with PPT_CLEAR_RATELIMIT_HALT=1 to resume. NOT publishing.`);
    } else {
      console.log("[overnight] stopped — progress persisted; re-run to resume. NOT publishing.");
    }
    process.exitCode = 2;
    return;
  }

  const setsRemaining = sets.filter((s) => !setsDone.has(s.setId)).length;
  const idCount = (db.prepare("SELECT COUNT(DISTINCT tcgplayer_id) AS n FROM card WHERE tcgplayer_id IS NOT NULL").get() as any).n as number;
  const popRemaining = sc.probe.populationEnabled ? Math.ceil(idCount / 50) - popBatchesDone.size : 0;
  if (setsRemaining > 0 || popRemaining > 0) { console.log(`[overnight] ${setsRemaining} sets / ${popRemaining} pop batches remain — re-run to continue. NOT publishing.`); process.exitCode = 2; return; }

  console.log(`[overnight] all phases complete — publishing catalog v${version} to ${resolvedOut}/catalog/ …`);
  const manifest = await publishCatalog(dbPath, version, new LocalStorage(resolvedOut), new Date());
  console.log(`[overnight] published v${manifest.version} · ${manifest.sizeBytes.toLocaleString()} gz bytes · sha256 ${manifest.sha256}`);
  console.log(`[overnight] upload (HOLD for owner go): gcloud storage cp ${resolvedOut}/catalog/{manifest.json,${manifest.path.split("/").pop()}} gs://${process.env.FIREBASE_STORAGE_BUCKET ?? "<your-bucket>"}/catalog/`);
}

main().catch((e) => { console.error(e); process.exit(1); });
