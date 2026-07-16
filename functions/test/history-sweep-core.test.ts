import { describe, it, expect } from "vitest";
import Database from "better-sqlite3";
import { runHistorySweep, HistoryClient, SweepSet, SweepProgress } from "../src/pipeline/history-sweep-core";
import { CreditBudgetExceeded } from "../src/upstream/ppt";

/** Minimal in-memory catalog with the two tables the sweep touches. */
function makeDb() {
  const db = new Database(":memory:");
  db.exec(`
    CREATE TABLE card(id TEXT PRIMARY KEY, set_id TEXT NOT NULL, number TEXT NOT NULL, name TEXT NOT NULL);
    CREATE TABLE price_history(card_id TEXT NOT NULL, date TEXT NOT NULL, raw_usd REAL NOT NULL,
      PRIMARY KEY(card_id, date));
  `);
  const ins = db.prepare("INSERT INTO card VALUES (?,?,?,?)");
  ins.run("swsh7-215", "swsh7", "215", "Umbreon VMAX");
  ins.run("swsh7-12", "swsh7", "12", "Metapod");
  ins.run("cel25-1", "cel25", "1", "Ho-Oh");
  return db;
}

function memProgress(done: string[] = []): SweepProgress {
  const doneSets = new Set(done);
  return { doneSets, markDone: (id) => doneSets.add(id) };
}

const neverStop = () => false;

describe("runHistorySweep", () => {
  it("matches PPT cards to our ids by number and writes weekly rows", async () => {
    const db = makeDb();
    const client: HistoryClient = {
      async getSetHistory(name) {
        if (name === "Evolving Skies") return [
          { tcgPlayerId: 1, cardNumber: "215", name: "Umbreon VMAX",
            priceHistory: [{ date: "2026-01-05", price: 88 }, { date: "2026-01-12", price: 90 }] },
          { tcgPlayerId: 2, cardNumber: "12", name: "Metapod", priceHistory: [{ date: "2026-01-05", price: 1 }] },
        ];
        return [{ tcgPlayerId: 3, cardNumber: "1", name: "Ho-Oh", priceHistory: [{ date: "2026-01-05", price: 5 }] }];
      },
    };
    const sets: SweepSet[] = [{ setId: "swsh7", pptName: "Evolving Skies" }, { setId: "cel25", pptName: "Celebrations" }];
    const summary = await runHistorySweep(db, client, sets, memProgress(), neverStop);
    expect(summary.setsDone).toBe(2);
    expect(db.prepare("SELECT COUNT(*) c FROM price_history").get()).toEqual({ c: 4 });
    expect(db.prepare("SELECT date, raw_usd FROM price_history WHERE card_id='swsh7-215' ORDER BY date").all())
      .toEqual([{ date: "2026-01-05", raw_usd: 88 }, { date: "2026-01-12", raw_usd: 90 }]);
  });

  it("skips sets already in progress.doneSets", async () => {
    const db = makeDb();
    let calls = 0;
    const client: HistoryClient = { async getSetHistory() { calls++; return []; } };
    const sets: SweepSet[] = [{ setId: "swsh7", pptName: "Evolving Skies" }];
    const summary = await runHistorySweep(db, client, sets, memProgress(["swsh7"]), neverStop);
    expect(calls).toBe(0);
    expect(summary.setsDone).toBe(0);
  });

  it("is idempotent — a second run does not duplicate rows", async () => {
    const db = makeDb();
    const client: HistoryClient = {
      async getSetHistory() { return [{ tcgPlayerId: 1, cardNumber: "215", name: "Umbreon VMAX",
        priceHistory: [{ date: "2026-01-05", price: 88 }] }]; },
    };
    const sets: SweepSet[] = [{ setId: "swsh7", pptName: "Evolving Skies" }];
    await runHistorySweep(db, client, sets, memProgress(), neverStop);
    await runHistorySweep(db, client, sets, memProgress(), neverStop); // fresh progress → re-fetch
    expect(db.prepare("SELECT COUNT(*) c FROM price_history").get()).toEqual({ c: 1 });
  });

  it("stops gracefully on a stop error, preserving completed sets and marking them done", async () => {
    const db = makeDb();
    const progress = memProgress();
    const client: HistoryClient = {
      async getSetHistory(name) {
        if (name === "Evolving Skies") return [{ tcgPlayerId: 1, cardNumber: "215", name: "Umbreon VMAX",
          priceHistory: [{ date: "2026-01-05", price: 88 }] }];
        throw new CreditBudgetExceeded();
      },
    };
    const sets: SweepSet[] = [{ setId: "swsh7", pptName: "Evolving Skies" }, { setId: "cel25", pptName: "Celebrations" }];
    const summary = await runHistorySweep(db, client, sets, progress, (e) => e instanceof CreditBudgetExceeded);
    expect(summary.stoppedEarly).toBe(true);
    expect(summary.setsDone).toBe(1);
    expect(progress.doneSets.has("swsh7")).toBe(true);
    expect(progress.doneSets.has("cel25")).toBe(false);
    expect(db.prepare("SELECT COUNT(*) c FROM price_history").get()).toEqual({ c: 1 });
  });
});

import { loadDoneSets, appendDoneSet } from "../src/pipeline/history-sweep-core";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("sidecar progress ledger", () => {
  it("round-trips done sets and treats a missing file as empty", () => {
    const path = join(mkdtempSync(join(tmpdir(), "sweep-")), "cat.sqlite.sweep-progress.json");
    expect(loadDoneSets(path).size).toBe(0);
    appendDoneSet(path, "swsh7");
    appendDoneSet(path, "cel25");
    expect(loadDoneSets(path)).toEqual(new Set(["swsh7", "cel25"]));
    appendDoneSet(path, "swsh7"); // idempotent
    expect(loadDoneSets(path).size).toBe(2);
  });
});
