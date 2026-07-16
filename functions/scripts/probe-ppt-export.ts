/**
 * Pull the PPT Business-tier bulk EXPORT dumps — LIVE, needs a Business ($99/mo) key.
 *
 *   PPT_BUSINESS=<key> npx tsx scripts/probe-ppt-export.ts [datasets=cards,sealed]
 *
 * The Business tier exposes `GET /api/v2/export?type={cards|sealed|ebay|population}`, which
 * 302-redirects to a public Vercel-Blob gzip-CSV. PPT regenerates the dumps ONCE A DAY at
 * ~06:01 UTC (observed via X-Dump-Generated-At across multiple days), and the export quota is a
 * SHARED ~2 downloads/day pool — the 302 itself spends a download, and there is no free way to
 * check dump freshness first (the blob URL is stable but sits behind a CDN that serves stale
 * HEAD responses for many hours, and Last-Modified moves on every customer's pull, not on
 * regeneration). So freshness is managed with what we can know locally:
 *
 *   - A meta sidecar ({dataset}-latest.meta.json in SAVE_DIR) records X-Dump-Generated-At of the
 *     last successful pull. If the cache already holds the newest dump that can exist right now
 *     (generated-at >= the most recent ~06:00Z boundary before now), the pull is SKIPPED — the
 *     API would only hand back identical bytes and burn the day's quota.
 *   - If the next daily generation is due within EXPORT_WAIT_MINS (default 0 = never wait; the
 *     nightly entrypoint sets it), sleep until ~06:10Z first and pull the fresh dump instead of
 *     spending quota on the old one.
 *   - After a pull, if the dump is still older than the last generation boundary (PPT generated
 *     late/failed), a grep-able "STALE DUMP" warning is printed — the nightly entrypoint turns
 *     that into a notification ping. No same-night retry: the shared 2/day quota can't fund
 *     one, and yesterday's prices are an acceptable degradation for one night.
 *
 * QUOTA / BAN SAFETY: a 429/403 response stops that dataset and is NEVER retried (retrying a
 * rate-limited request is exactly what earns a PPT key ban). Network-layer failures (connect
 * timeout, DNS, reset) never reached the server, so those ARE retried on a short ladder.
 */
import { gunzipSync } from "node:zlib";
import { writeFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
import { isTransientNetworkError } from "../src/upstream/ppt";

const BASE = "https://www.pokemonpricetracker.com/api/v2";
const KEY = process.env.PPT_BUSINESS || process.env.PPT_API_KEY || process.env.PPT_PAID;
// Set SAVE_DIR to keep the full CSV (quota is 2/day, so download once and re-run the pipeline
// locally against the saved file): SAVE_DIR=.export-cache PPT_PAID=… npx tsx scripts/probe-ppt-export.ts cards
const SAVE_DIR = process.env.SAVE_DIR;
/** Hour (UTC) of PPT's daily dump regeneration. Observed 06:01:4xZ on consecutive days; the
 *  10-minute GEN_GRACE below absorbs the minutes-level jitter. If PPT ever moves this, the
 *  post-pull STALE-DUMP check is the backstop that tells us. */
const GEN_UTC_HOUR = Number(process.env.EXPORT_GEN_UTC_HOUR) || 6;
const GEN_GRACE_MS = 10 * 60_000;
const WAIT_CAP_MS = (Number(process.env.EXPORT_WAIT_MINS) || 0) * 60_000;
const NET_RETRY_DELAYS_MS = [30_000, 90_000];

const KNOWN = new Set(["cards", "sealed", "ebay", "population"]);

interface Meta { dumpGeneratedAt: string; pulledAt: string; location: string | null; }
const metaPath = (dataset: string) => `${SAVE_DIR}/${dataset}-latest.meta.json`;
function loadMeta(dataset: string): Meta | null {
  if (!SAVE_DIR || !existsSync(metaPath(dataset))) return null;
  try { return JSON.parse(readFileSync(metaPath(dataset), "utf8")); } catch { return null; }
}

/** Most recent daily generation boundary (~06:00Z) at or before `now`. */
function lastGenBoundary(now: Date): Date {
  const b = new Date(now);
  b.setUTCHours(GEN_UTC_HOUR, 0, 0, 0);
  if (b.getTime() > now.getTime()) b.setUTCDate(b.getUTCDate() - 1);
  return b;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** fetch with a short retry ladder for network-layer errors ONLY (a served 429/403 never
 *  throws, so this cannot re-fire a rate-limited request). */
async function fetchWithNetRetry(url: string, init?: RequestInit): Promise<Response> {
  for (let attempt = 0; ; attempt++) {
    try { return await fetch(url, init); }
    catch (e) {
      if (!isTransientNetworkError(e) || attempt >= NET_RETRY_DELAYS_MS.length) throw e;
      const delay = NET_RETRY_DELAYS_MS[attempt];
      console.warn(`[export] network error (${(e as Error).message}) — retry ${attempt + 1}/${NET_RETRY_DELAYS_MS.length} in ${delay / 1000}s`);
      await sleep(delay);
    }
  }
}

async function probe(dataset: string, key: string, cutoff: Date): Promise<void> {
  console.log(`\n=== dataset: ${dataset} ===`);
  // redirect: "manual" so we can SEE a Location header rather than silently following it.
  // NB: the query param is `type=` (docs), and the endpoint 302-redirects to a Vercel Blob URL.
  const res = await fetchWithNetRetry(`${BASE}/export?type=${dataset}`, {
    headers: { Authorization: `Bearer ${key}` },
    redirect: "manual",
  });
  const h = (name: string) => res.headers.get(name) ?? "(none)";
  console.log(`status: ${res.status}`);
  console.log(`content-type: ${h("content-type")}`);
  console.log(`location: ${h("location")}`);
  console.log(`x-export-downloads-remaining: ${h("x-export-downloads-remaining")}`);
  console.log(`x-dump-generated-at: ${h("x-dump-generated-at")}`);

  if (res.status === 429 || res.status === 403) {
    console.log(`! ${res.status} — stopping this dataset (quota/plan). No retry (ban safety). REUSING CACHE if present.`);
    return;
  }

  const generatedAtRaw = res.headers.get("x-dump-generated-at");
  const generatedAt = generatedAtRaw ? new Date(generatedAtRaw) : null;
  if (generatedAt && !Number.isNaN(generatedAt.getTime()) && generatedAt.getTime() < cutoff.getTime()) {
    // Quota for this dataset is already spent (the 302 above charged it) — download anyway, the
    // bytes are the newest PPT has. The warning is the signal that tonight's prices are a day old.
    console.warn(`[export] STALE DUMP for ${dataset}: generated ${generatedAtRaw}, expected >= ${cutoff.toISOString()} — PPT regeneration is late; using it anyway.`);
  }

  // Two documented shapes: (a) redirect/200 whose body IS the gzip file, or (b) a Location /
  // JSON `url` pointing at a signed file URL we then fetch (no auth on the signed URL).
  let fileUrl: string | null = res.headers.get("location");
  let bytes: Buffer | null = null;
  const ctype = res.headers.get("content-type") ?? "";

  if (!fileUrl && ctype.includes("json")) {
    const body: any = await res.json();
    fileUrl = body?.url ?? body?.location ?? body?.href ?? null;
    console.log(`json body keys: ${Object.keys(body ?? {}).join(", ")}`);
  } else if (!fileUrl) {
    bytes = Buffer.from(await res.arrayBuffer()); // body is the file directly
  }

  if (fileUrl && !bytes) {
    const fileRes = await fetchWithNetRetry(fileUrl); // signed URL — no Authorization header
    if (!fileRes.ok) { console.log(`! file fetch ${fileRes.status} for ${fileUrl}`); return; }
    bytes = Buffer.from(await fileRes.arrayBuffer());
  }
  if (!bytes) { console.log("! no file bytes resolved"); return; }

  // Persist the raw bytes the instant the (quota-costing) download lands — BEFORE gunzip/parse,
  // which is the step most likely to throw. A rerun then mocks the download from disk; the daily
  // export budget is never spent twice for one failed pipeline.
  if (SAVE_DIR) {
    mkdirSync(SAVE_DIR, { recursive: true });
    writeFileSync(`${SAVE_DIR}/${dataset}-latest.raw`, bytes);
  }

  // Gunzip if gzip-magic (0x1f 0x8b); otherwise assume it's already plain CSV.
  const csv = (bytes[0] === 0x1f && bytes[1] === 0x8b) ? gunzipSync(bytes).toString("utf8") : bytes.toString("utf8");
  const lines = csv.split(/\r?\n/).filter((l) => l.length > 0);
  console.log(`rows (incl header): ${lines.length}`);
  console.log(`header: ${lines[0] ?? "(empty)"}`);
  for (let i = 1; i <= 3 && i < lines.length; i++) console.log(`row ${i}: ${lines[i]}`);
  if (SAVE_DIR) {
    mkdirSync(SAVE_DIR, { recursive: true });
    const path = `${SAVE_DIR}/${dataset}-latest.csv`;
    writeFileSync(path, csv);
    console.log(`saved: ${path}`);
    if (generatedAt && !Number.isNaN(generatedAt.getTime())) {
      const meta: Meta = { dumpGeneratedAt: generatedAt.toISOString(), pulledAt: new Date().toISOString(), location: fileUrl };
      writeFileSync(metaPath(dataset), JSON.stringify(meta));
    }
  }
}

async function main(): Promise<void> {
  if (!KEY) { console.error("Set PPT_BUSINESS (or PPT_API_KEY / PPT_PAID) to a Business-tier key."); process.exit(1); }
  const requested = (process.argv[2] ?? "cards,sealed").split(",").map((s) => s.trim()).filter(Boolean);
  const bad = requested.filter((d) => !KNOWN.has(d));
  if (bad.length) { console.error(`Unknown dataset(s): ${bad.join(", ")}. Known: ${[...KNOWN].join(", ")}`); process.exit(1); }
  if (requested.length > 2) console.warn(`⚠ ${requested.length} datasets requested but export quota is ~2/day — later ones may 429.`);

  // If the next daily regeneration lands within EXPORT_WAIT_MINS, wait for it rather than
  // spending the shared 2/day quota on a dump that is about to be replaced.
  let now = new Date();
  let cutoff = lastGenBoundary(now);
  const nextReady = cutoff.getTime() + 24 * 3_600_000 + GEN_GRACE_MS;
  if (WAIT_CAP_MS > 0 && nextReady - now.getTime() <= WAIT_CAP_MS) {
    console.log(`[export] next dump regeneration due ${new Date(nextReady).toISOString()} — waiting ${Math.round((nextReady - now.getTime()) / 60000)}min for it before spending quota.`);
    await sleep(nextReady - now.getTime());
    now = new Date();
    cutoff = lastGenBoundary(now);
  }

  for (const dataset of requested) {
    // Skip-gate: if the cache already holds the newest dump that can exist right now, a pull
    // would return identical bytes and waste the day's quota (e.g. the pipeline ran twice today,
    // or a manual run already pulled after the 06:00Z regeneration).
    const meta = loadMeta(dataset);
    if (meta && SAVE_DIR && existsSync(`${SAVE_DIR}/${dataset}-latest.csv`)
        && new Date(meta.dumpGeneratedAt).getTime() >= cutoff.getTime()) {
      console.log(`\n=== dataset: ${dataset} ===\n[export] SKIP-FRESH: cache already has the current dump (generated ${meta.dumpGeneratedAt}, boundary ${cutoff.toISOString()}) — not spending quota.`);
      continue;
    }
    try { await probe(dataset, KEY, cutoff); }
    catch (e) { console.log(`! error probing ${dataset}: ${(e as Error).message} — REUSING CACHE if present.`); }
  }
  console.log("\nDone. Paste the headers + CSV columns back to wire up the nightly parser.");
}

void main();
