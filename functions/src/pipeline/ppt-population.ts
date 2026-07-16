export interface PopulationRow {
  tcgPlayerId: number; grader: string; grade: string;
  count: number; gemRate: number | null; totalPopulation: number | null;
}

const SUMMARY_KEYS = new Set(["totalPopulation", "gemRate"]);

function num(v: unknown): number | null {
  const n = typeof v === "string" ? Number(v) : (v as number);
  return typeof n === "number" && Number.isFinite(n) ? n : null;
}

/** Flatten PPT `/population` body → per (card, grader, grade) rows. Shape-tolerant:
 *  `data` may be one object or an array; unknown/summary keys are ignored. */
export function parsePopulation(body: unknown): PopulationRow[] {
  const data = (body as any)?.data;
  const entries: any[] = Array.isArray(data) ? data : data ? [data] : [];
  const out: PopulationRow[] = [];
  for (const e of entries) {
    const tcgPlayerId = num(e?.tcgPlayerId);
    const byGrader = e?.populationByGrader;
    if (tcgPlayerId == null || !byGrader || typeof byGrader !== "object") continue;
    for (const [grader, stats] of Object.entries(byGrader)) {
      if (!stats || typeof stats !== "object") continue;
      const gemRate = num((stats as any).gemRate);
      const totalPopulation = num((stats as any).totalPopulation);
      for (const [grade, v] of Object.entries(stats as Record<string, unknown>)) {
        if (SUMMARY_KEYS.has(grade)) continue;
        const count = num(v);
        if (count == null) continue;
        out.push({ tcgPlayerId, grader, grade, count, gemRate, totalPopulation });
      }
    }
  }
  return out;
}
