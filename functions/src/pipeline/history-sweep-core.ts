import { existsSync, readFileSync, writeFileSync } from "node:fs";
import type { Database as Db } from "better-sqlite3";
import { normalizeNumber } from "./matcher";
import { parseWeeklyHistory } from "./ppt-history";
import type { PptHistoryCard } from "../upstream/ppt";

export interface HistoryClient {
  getSetHistory(setName: string, cardCountHint: number): Promise<PptHistoryCard[]>;
}
export interface SweepSet { setId: string; pptName: string; }
export interface SweepProgress { doneSets: Set<string>; markDone(setId: string): void; }
export interface SweepSummary { setsDone: number; rowsWritten: number; stoppedEarly: boolean; stopReason?: string; }

interface OurCard { id: string; number: string; name: string; }
function normName(n: string): string { return n.toLowerCase().replace(/[^a-z0-9]/g, ""); }

/**
 * Fill `price_history` for each set not already in `progress.doneSets`. Matches each PPT history-card
 * to our card id by number (disambiguating same-number candidates by name), writes weekly USD rows
 * idempotently (INSERT OR REPLACE), and records each completed set. On a stop error (credit budget /
 * rate limit — decided by `isStopError`), returns with `stoppedEarly=true`; partial progress is durable.
 */
export async function runHistorySweep(
  db: Db,
  client: HistoryClient,
  sets: SweepSet[],
  progress: SweepProgress,
  isStopError: (e: unknown) => boolean,
): Promise<SweepSummary> {
  const ins = db.prepare("INSERT OR REPLACE INTO price_history(card_id, date, raw_usd) VALUES (?,?,?)");
  const ourStmt = db.prepare("SELECT id, number, name FROM card WHERE set_id = ?");
  let setsDone = 0, rowsWritten = 0;

  for (const s of sets) {
    if (progress.doneSets.has(s.setId)) continue;

    const our = ourStmt.all(s.setId) as OurCard[];
    const byNum = new Map<string, OurCard[]>();
    for (const c of our) {
      const k = normalizeNumber(c.number);
      (byNum.get(k) ?? byNum.set(k, []).get(k)!).push(c);
    }

    let pptCards: PptHistoryCard[];
    try {
      pptCards = await client.getSetHistory(s.pptName, our.length);
    } catch (e) {
      if (isStopError(e)) return { setsDone, rowsWritten, stoppedEarly: true, stopReason: (e as Error).message };
      throw e;
    }

    const write = db.transaction((cards: PptHistoryCard[]) => {
      for (const pc of cards) {
        const cands = byNum.get(normalizeNumber(pc.cardNumber)) ?? [];
        const match = cands.length === 1 ? cands[0] : cands.find((c) => normName(c.name) === normName(pc.name)) ?? null;
        if (!match) continue;
        for (const wp of parseWeeklyHistory(pc.priceHistory)) {
          ins.run(match.id, wp.date, wp.rawUsd);
          rowsWritten++;
        }
      }
    });
    write(pptCards);

    progress.markDone(s.setId);
    setsDone++;
  }
  return { setsDone, rowsWritten, stoppedEarly: false };
}

// ---- Sidecar progress ledger (never ships in the artifact) ----

/** Load the set ids already completed, from `<db-path>.sweep-progress.json`. Missing/corrupt → empty. */
export function loadDoneSets(path: string): Set<string> {
  if (!existsSync(path)) return new Set();
  try {
    const j = JSON.parse(readFileSync(path, "utf8"));
    return new Set(Array.isArray(j.doneSets) ? j.doneSets : []);
  } catch {
    return new Set();
  }
}

/** Append a completed set id and persist immediately (durable across process kills). */
export function appendDoneSet(path: string, setId: string): void {
  const done = loadDoneSets(path);
  done.add(setId);
  writeFileSync(path, JSON.stringify({ doneSets: [...done], updatedAt: new Date().toISOString() }));
}
