export type GradedHistoryMode = "timeseries" | "latest-only";
export interface GradedHistoryPoint { grade: string; date: string; usd: number; }

/** Coerce to a finite number (numeric strings included), else null. Sign-agnostic. */
function num(v: unknown): number | null {
  const n = typeof v === "string" ? Number(v) : (v as number);
  return typeof n === "number" && Number.isFinite(n) ? n : null;
}

/** First candidate that is a finite, strictly-positive number, else null. */
function firstPositive(...vals: unknown[]): number | null {
  for (const v of vals) {
    const n = num(v);
    if (n != null && n > 0) return n;
  }
  return null;
}

const DATE_KEY_RE = /^\d{4}-\d{2}-\d{2}/;

/** Latest graded snapshot from `ebay.salesByGrade`: `{ grade: latestPrice }`, where latestPrice
 *  is the first finite, positive value of smartMarketPrice.price, medianPrice, averagePrice. */
export function parseLatestGraded(ebay: unknown): Record<string, number | null> {
  const out: Record<string, number | null> = {};
  if (!ebay || typeof ebay !== "object") return out;
  const salesByGrade = (ebay as Record<string, unknown>).salesByGrade;
  if (!salesByGrade || typeof salesByGrade !== "object") return out;
  for (const [grade, stats] of Object.entries(salesByGrade as Record<string, any>)) {
    out[grade] = firstPositive(stats?.smartMarketPrice?.price, stats?.medianPrice, stats?.averagePrice);
  }
  return out;
}

/** Is there at least one dated (YYYY-MM-DD) per-grade point in `ebay.priceHistory` with a
 *  finite numeric `average`? */
export function detectGradedHistoryMode(ebay: unknown): GradedHistoryMode {
  if (ebay && typeof ebay === "object") {
    const priceHistory = (ebay as Record<string, unknown>).priceHistory;
    if (priceHistory && typeof priceHistory === "object") {
      for (const gradeVal of Object.values(priceHistory as Record<string, unknown>)) {
        if (!gradeVal || typeof gradeVal !== "object") continue;
        for (const [dateKey, point] of Object.entries(gradeVal as Record<string, unknown>)) {
          if (DATE_KEY_RE.test(dateKey) && point && typeof point === "object" && num((point as any).average) != null) {
            return "timeseries";
          }
        }
      }
    }
  }
  return "latest-only";
}

/** Flatten `ebay.priceHistory[grade][date].average` to points, for every dated point with a
 *  finite, strictly-positive `average`. */
export function parseGradedHistory(ebay: unknown): GradedHistoryPoint[] {
  const out: GradedHistoryPoint[] = [];
  if (!ebay || typeof ebay !== "object") return out;
  const priceHistory = (ebay as Record<string, unknown>).priceHistory;
  if (!priceHistory || typeof priceHistory !== "object") return out;
  for (const [grade, gradeVal] of Object.entries(priceHistory as Record<string, unknown>)) {
    if (!gradeVal || typeof gradeVal !== "object") continue;
    for (const [dateKey, point] of Object.entries(gradeVal as Record<string, unknown>)) {
      if (!DATE_KEY_RE.test(dateKey) || !point || typeof point !== "object") continue;
      const usd = firstPositive((point as any).average);
      if (usd != null) out.push({ grade, date: dateKey.slice(0, 10), usd });
    }
  }
  return out;
}
