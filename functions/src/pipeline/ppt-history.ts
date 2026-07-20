export interface WeeklyPoint {
  date: string; // YYYY-MM-DD (UTC)
  rawUsd: number;
}

const DAY_MS = 86_400_000;

/** Parse a date value that may be an ISO string, a YYYY-MM-DD string, or epoch seconds/ms. */
function parseDate(v: unknown): Date | null {
  if (typeof v === "number") {
    const ms = v < 1e12 ? v * 1000 : v; // treat small numbers as epoch seconds
    const d = new Date(ms);
    return isNaN(d.getTime()) ? null : d;
  }
  if (typeof v === "string") {
    const s = /^\d{4}-\d{2}-\d{2}$/.test(v) ? `${v}T00:00:00Z` : v;
    const d = new Date(s);
    return isNaN(d.getTime()) ? null : d;
  }
  return null;
}

/** Pull a numeric price from a number, or from a nested object's market/price/value/usd field.
 *  Requires a positive value — a bogus `0` or negative market point must not be written to
 *  `price_history`. */
function parsePrice(v: unknown): number | null {
  if (typeof v === "number") return Number.isFinite(v) && v > 0 ? v : null;
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    const n = Number(o.market ?? o.price ?? o.marketPrice ?? o.value ?? o.usd);
    return Number.isFinite(n) && n > 0 ? n : null;
  }
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : null;
}

/** Flatten PPT's `priceHistory` (nested conditions map, array-of-objects, OR object-map) to raw
 *  {date, price} points. */
function toRawPoints(priceHistory: unknown): { date: Date; price: number }[] {
  const out: { date: Date; price: number }[] = [];
  const push = (dateVal: unknown, priceVal: unknown) => {
    const date = parseDate(dateVal);
    const price = parsePrice(priceVal);
    if (date && price != null) out.push({ date, price });
  };
  const pushHistoryArray = (history: unknown) => {
    if (!Array.isArray(history)) return;
    for (const p of history) {
      if (p && typeof p === "object") {
        const o = p as Record<string, unknown>;
        push(o.date ?? o.timestamp ?? o.t ?? o.day, o.price ?? o.market ?? o.marketPrice ?? o.value ?? o.usd ?? o);
      }
    }
  };
  // Real PPT shape: { conditions: { "Near Mint": { history: [...] }, ... }, ... }. Prefer "Near
  // Mint"; fall back to the first available condition.
  if (priceHistory && typeof priceHistory === "object" && !Array.isArray(priceHistory)) {
    const conditions = (priceHistory as Record<string, unknown>).conditions;
    if (conditions && typeof conditions === "object") {
      const condMap = conditions as Record<string, unknown>;
      const chosen = condMap["Near Mint"] ?? Object.values(condMap)[0];
      pushHistoryArray((chosen as Record<string, unknown> | undefined)?.history);
      return out;
    }
  }
  if (Array.isArray(priceHistory)) {
    pushHistoryArray(priceHistory);
  } else if (priceHistory && typeof priceHistory === "object") {
    for (const [k, v] of Object.entries(priceHistory as Record<string, unknown>)) push(k, v);
  }
  return out;
}

/**
 * Normalize PPT price history to weekly USD rows for the `price_history` table: dedup by exact
 * UTC date (latest price wins), then thin to >=6-day spacing (maxDataPoints=104 over 730 days already yields
 * ~weekly server-side; this makes it deterministic). Ascending by date.
 */
export function parseWeeklyHistory(priceHistory: unknown): WeeklyPoint[] {
  const raw = toRawPoints(priceHistory).sort((a, b) => a.date.getTime() - b.date.getTime());
  const byDay = new Map<string, number>();
  for (const p of raw) byDay.set(p.date.toISOString().slice(0, 10), p.price); // latest wins (ascending)
  const days = [...byDay.entries()].sort(([a], [b]) => (a < b ? -1 : 1));
  const out: WeeklyPoint[] = [];
  let lastMs = -Infinity;
  for (const [date, rawUsd] of days) {
    const ms = Date.parse(`${date}T00:00:00Z`);
    if (ms - lastMs >= 6 * DAY_MS) {
      out.push({ date, rawUsd });
      lastMs = ms;
    }
  }
  return out;
}

export interface ConditionSeries { condition: string; points: WeeklyPoint[]; }

/**
 * Per-condition weekly history from `priceHistory.conditions[condition].history[]` (the real PPT
 * shape). Every condition PPT sends (Near Mint, Lightly Played, Moderately Played, Heavily
 * Played, Damaged, ...) is captured verbatim — unlike `parseWeeklyHistory`, which only surfaces
 * Near Mint (or a fallback) for the app-facing `price_history` table. Conditions whose history
 * yields no points (e.g. an empty array) are skipped entirely. Shape-tolerant: garbage → [].
 */
export function parseConditionHistory(priceHistory: unknown): ConditionSeries[] {
  const out: ConditionSeries[] = [];
  if (!priceHistory || typeof priceHistory !== "object" || Array.isArray(priceHistory)) return out;
  const conditions = (priceHistory as Record<string, unknown>).conditions;
  if (!conditions || typeof conditions !== "object" || Array.isArray(conditions)) return out;
  for (const [condition, v] of Object.entries(conditions as Record<string, unknown>)) {
    const history = v && typeof v === "object" ? (v as Record<string, unknown>).history : undefined;
    const points = parseWeeklyHistory(history);
    if (points.length > 0) out.push({ condition, points });
  }
  return out;
}

export interface ConditionSales { condition: string; salesCount: number; }

/** Rolled-up ungraded sales count per condition: sum the per-day `volume` on
 *  `priceHistory.conditions[condition].history[]` for points within the last `windowDays`
 *  (relative to `asOf`, a YYYY-MM-DD). Conditions with no qualifying volume are omitted (→ no
 *  footnote in the app). Shape-tolerant: garbage → []. `volume` is a count — absent / non-finite /
 *  non-positive contributes 0. */
export const CONDITION_SALES_WINDOW_DAYS = 90;

export function parseConditionSales(
  priceHistory: unknown, asOf: string, windowDays = CONDITION_SALES_WINDOW_DAYS,
): ConditionSales[] {
  const out: ConditionSales[] = [];
  if (!priceHistory || typeof priceHistory !== "object" || Array.isArray(priceHistory)) return out;
  const conditions = (priceHistory as Record<string, unknown>).conditions;
  if (!conditions || typeof conditions !== "object" || Array.isArray(conditions)) return out;
  const cutoffMs = Date.parse(`${asOf}T00:00:00Z`) - windowDays * DAY_MS;
  if (!Number.isFinite(cutoffMs)) return out;
  for (const [condition, v] of Object.entries(conditions as Record<string, unknown>)) {
    const history = v && typeof v === "object" ? (v as Record<string, unknown>).history : undefined;
    if (!Array.isArray(history)) continue;
    let total = 0;
    for (const p of history) {
      if (!p || typeof p !== "object") continue;
      const o = p as Record<string, unknown>;
      const date = parseDate(o.date ?? o.timestamp ?? o.t ?? o.day);
      if (!date || date.getTime() < cutoffMs) continue;
      const vol = Number(o.volume);
      if (Number.isFinite(vol) && vol > 0) total += Math.trunc(vol);
    }
    if (total > 0) out.push({ condition, salesCount: total });
  }
  return out;
}

export interface ConditionLatest { condition: string; usd: number; }

export interface VariantLatest { printing: string; usd: number; }

/**
 * Latest market price per PRINTING from `prices.variants[printing][condition].price`. Unlike
 * `parseLatestByCondition` (which keeps only `primaryPrinting`), this keeps EVERY printing key
 * verbatim ("Normal", "Holofoil", "Reverse Holofoil", "1st Edition Holofoil", …) — one price per
 * printing, taken from Near Mint, falling back to the first finite strictly-positive condition.
 * Printings with no usable condition price are skipped. Shape-tolerant: garbage → [].
 */
export function parseLatestByVariant(prices: unknown): VariantLatest[] {
  const out: VariantLatest[] = [];
  if (!prices || typeof prices !== "object" || Array.isArray(prices)) return out;
  const variants = (prices as Record<string, unknown>).variants;
  if (!variants || typeof variants !== "object" || Array.isArray(variants)) return out;
  for (const [printing, byConditionRaw] of Object.entries(variants as Record<string, unknown>)) {
    if (!byConditionRaw || typeof byConditionRaw !== "object" || Array.isArray(byConditionRaw)) continue;
    const byCondition = byConditionRaw as Record<string, unknown>;
    const priceOf = (cond: string): number | null => {
      const v = byCondition[cond];
      if (!v || typeof v !== "object") return null;
      const n = Number((v as Record<string, unknown>).price);
      return Number.isFinite(n) && n > 0 ? n : null;
    };
    // Prefer Near Mint; otherwise the first condition with a usable price (stable key order).
    let usd = priceOf("Near Mint");
    if (usd == null) for (const cond of Object.keys(byCondition)) { const p = priceOf(cond); if (p != null) { usd = p; break; } }
    if (usd != null) out.push({ printing, usd });
  }
  return out;
}

/**
 * Latest price per ungraded condition from `prices.variants[primaryPrinting][condition].price`.
 * `primaryPrinting` defaults to `prices.primaryPrinting`, falling back to the first variant key
 * when absent. Only finite, strictly-positive prices are included. Shape-tolerant: garbage → [].
 */
export function parseLatestByCondition(prices: unknown): ConditionLatest[] {
  const out: ConditionLatest[] = [];
  if (!prices || typeof prices !== "object" || Array.isArray(prices)) return out;
  const p = prices as Record<string, unknown>;
  const variants = p.variants;
  if (!variants || typeof variants !== "object" || Array.isArray(variants)) return out;
  const variantMap = variants as Record<string, unknown>;
  const printingKey = typeof p.primaryPrinting === "string" ? p.primaryPrinting : Object.keys(variantMap)[0];
  if (printingKey == null) return out;
  const byCondition = variantMap[printingKey];
  if (!byCondition || typeof byCondition !== "object" || Array.isArray(byCondition)) return out;
  for (const [condition, v] of Object.entries(byCondition as Record<string, unknown>)) {
    if (!v || typeof v !== "object") continue;
    const n = Number((v as Record<string, unknown>).price);
    if (Number.isFinite(n) && n > 0) out.push({ condition, usd: n });
  }
  return out;
}

export interface MatrixCell { printing: string; condition: string; usd: number }

/**
 * EVERY printing×condition cell from `prices.variants[printing][condition].price` — the full
 * matrix that `parseLatestByVariant` (NM only) and `parseLatestByCondition` (primaryPrinting
 * only) each flatten one axis of. Keys stay PPT-verbatim. Only finite, strictly-positive
 * prices are included. Shape-tolerant: garbage → [].
 */
export function parseMatrix(prices: unknown): MatrixCell[] {
  const out: MatrixCell[] = [];
  if (!prices || typeof prices !== "object" || Array.isArray(prices)) return out;
  const variants = (prices as Record<string, unknown>).variants;
  if (!variants || typeof variants !== "object" || Array.isArray(variants)) return out;
  for (const [printing, byConditionRaw] of Object.entries(variants as Record<string, unknown>)) {
    if (!byConditionRaw || typeof byConditionRaw !== "object" || Array.isArray(byConditionRaw)) continue;
    for (const [condition, v] of Object.entries(byConditionRaw as Record<string, unknown>)) {
      if (!v || typeof v !== "object") continue;
      const n = Number((v as Record<string, unknown>).price);
      if (Number.isFinite(n) && n > 0) out.push({ printing, condition, usd: n });
    }
  }
  return out;
}

export interface Liquidity { sellers: number | null; listings: number | null }

/** Marketplace liquidity off the top-level `prices` object: how many sellers/listings back the
 *  raw market price. Shape-tolerant: absent/garbage → nulls (the trimmed test fixture predates
 *  these fields; live /cards responses carry them). Negative counts are bogus → null. */
export function parseLiquidity(prices: unknown): Liquidity {
  const out: Liquidity = { sellers: null, listings: null };
  if (!prices || typeof prices !== "object" || Array.isArray(prices)) return out;
  const p = prices as Record<string, unknown>;
  const count = (v: unknown): number | null => {
    const n = typeof v === "string" ? Number(v) : (v as number);
    return typeof n === "number" && Number.isFinite(n) && n >= 0 ? Math.trunc(n) : null;
  };
  out.sellers = count(p.sellers);
  out.listings = count(p.listings);
  return out;
}
