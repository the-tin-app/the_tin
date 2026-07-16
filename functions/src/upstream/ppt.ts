import type { FetchFn } from "./tcgdex";
import { MinuteRateLimiter } from "./rate-limiter";
import { parseLatestGraded, parseGradedHistory, type GradedHistoryPoint } from "../pipeline/ppt-graded";
import { parsePopulation, type PopulationRow } from "../pipeline/ppt-population";

export interface PptPrice {
  tcgPlayerId: number; setName: string; cardNumber: string; name: string;
  raw: number | null; graded: Record<string, number | null>;
}

export interface PptCard {
  externalCatalogId: string | null;
  cardNumber: string;
  name: string;
  imageUrl: string | null;
  marketUsd: number | null;
}

export interface PptHistoryCard {
  tcgPlayerId: number | null;
  cardNumber: string;
  name: string;
  priceHistory: unknown; // shape normalized by ppt-history.parseWeeklyHistory
}

export interface PptEnrichmentCard {
  tcgPlayerId: number | null; cardNumber: string; name: string;
  priceHistory: unknown; gradedLatest: Record<string, number | null>;
  gradedSeries: GradedHistoryPoint[]; ebayRaw: unknown;
  /** Raw `prices` object from PPT (primaryPrinting + variants[printing][condition].price),
   *  carried through unparsed so `ppt-history.parseLatestByCondition` can read all ungraded
   *  conditions (not just Near Mint). */
  pricesRaw: unknown;
}

export class CreditBudgetExceeded extends Error {
  constructor(msg = "PPT daily credit budget exceeded") { super(msg); this.name = "CreditBudgetExceeded"; }
}

/**
 * Parses the PPT daily credit budget from an env var, falling back to a safe
 * default whenever the raw value is missing, empty, non-numeric, zero, or
 * negative. This prevents `Number("")` (0, fail-closed) or `Number("abc")`
 * (NaN, which silently disables the budget check) from reaching CreditBudget.
 */
export function parseCreditBudget(raw: string | undefined, fallback = 15000): number {
  if (raw === undefined) return fallback;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

export class CreditBudget {
  private used = 0;
  constructor(private limit: number) {
    if (!Number.isFinite(limit) || limit <= 0) {
      throw new Error(`CreditBudget limit must be a positive finite number, got ${limit}`);
    }
  }
  spend(n: number): void {
    if (this.used + n > this.limit) throw new CreditBudgetExceeded();
    this.used += n;
  }
  get spent(): number { return this.used; }
}

const BASE = "https://www.pokemonpricetracker.com/api/v2";

export type SleepFn = (ms: number) => Promise<void>;
const realSleep: SleepFn = (ms) => new Promise((r) => setTimeout(r, ms));

/** Default fallback wait (ms) when a 429 arrives without a usable Retry-After header. PPT's
 *  window is per-minute, so ~60s is the safe reset. */
const DEFAULT_BACKOFF_MS = 60_000;
/** How many times to honor Retry-After and re-send before giving up (then the caller stops). */
const MAX_RETRY_AFTER_WAITS = 2;
/** Pause when the server-reported per-minute budget remaining drops below this — a safety net
 *  for a cost under-estimate; the MinuteRateLimiter (PPT_MINUTE_LIMIT, default 45/min) is the
 *  primary guard. Tier-agnostic (works against the 60/min pro or 500/min Business ceiling):
 *  a server-side accounting surprise still leaves room to stop before producing a 429. */
const MINUTE_REMAINING_FLOOR = 30;

/** Backoff ladder for transient network failures (connect timeout, DNS, reset). Unlike a 429,
 *  these requests never produced a server response, so re-sending cannot count against PPT's
 *  per-minute window — retrying here carries no ban risk. Total ~5.5min of waiting rides out
 *  short blips; a real outage exhausts the ladder and the error propagates to the caller
 *  (whose sidecar/resume machinery turns it into a stop-and-resume-tomorrow, not a crash). */
const NETWORK_RETRY_DELAYS_MS = [5_000, 15_000, 45_000, 90_000, 180_000];

const TRANSIENT_NET_CODES = new Set([
  "UND_ERR_CONNECT_TIMEOUT", "UND_ERR_SOCKET", "UND_ERR_HEADERS_TIMEOUT", "UND_ERR_BODY_TIMEOUT",
  "ECONNRESET", "ECONNREFUSED", "ETIMEDOUT", "EAI_AGAIN", "ENETUNREACH", "EHOSTUNREACH", "EPIPE",
]);

/** True for network-layer failures where the request never completed (fetch THREW — a served
 *  4xx/5xx response never throws, so this can never mask a rate-limit signal). Walks the cause
 *  chain because undici buries the real code: TypeError("fetch failed") → ConnectTimeoutError. */
export function isTransientNetworkError(e: unknown): boolean {
  for (let cur = e as any, depth = 0; cur && depth < 5; cur = cur.cause, depth++) {
    if (typeof cur.code === "string" && TRANSIENT_NET_CODES.has(cur.code)) return true;
    if (typeof cur.message === "string" && /fetch failed|socket hang up|other side closed/i.test(cur.message)) return true;
  }
  return false;
}
/** Worst-case minute-cost of a single `getSetHistory` (fetchAllInSet+includeHistory) request.
 *  PPT bills by ITS OWN set card count, not ours, and `ppt-setmap.ts` maps several of our sets
 *  (trainer-kit halves, promo aliases) onto a LARGER PPT set — so a hint derived from our catalog
 *  can under-count the true cost. Reserving the fixed cap (rather than deriving from the hint)
 *  makes the reservation an upper bound on the real cost always, which is what keeps the
 *  MinuteRateLimiter's per-minute invariant airtight. */
const HISTORY_REQUEST_MINUTE_COST = 30;

export class PptClient {
  constructor(
    private apiKey: string,
    private budget: CreditBudget,
    private fetchFn: FetchFn = fetch,
    private sleep: SleepFn = realSleep,
    // Default 45/min is safe for the old 60/min pro tier. Business is 500/min — set
    // PPT_MINUTE_LIMIT (e.g. 400, a safe 80% of the ceiling) to use that headroom.
    private limiter: MinuteRateLimiter = new MinuteRateLimiter(Number(process.env.PPT_MINUTE_LIMIT) || 45),
  ) {}

  lastHeaders = { minuteLimit: NaN, minuteRemaining: NaN, purchasedRemaining: NaN, dailyRemaining: NaN };

  private headerNum(res: any, name: string): number {
    const raw = res?.headers?.get?.(name);
    // A missing header reads as null/undefined/"" — must be NaN, NOT Number(null)===0, or an
    // absent X-RateLimit-Remaining would falsely look "exhausted" and trigger a 60s pause.
    if (raw == null || raw === "") return NaN;
    const v = Number(raw);
    return Number.isFinite(v) ? v : NaN;
  }

  /**
   * Rate-limit-aware request. PPT bans a key after too many 429s in a 5-minute window
   * (1h → 24h → 7d → permanent), so the rules are strict:
   *   - On 429, wait EXACTLY the server's Retry-After (never a guessed short backoff, and
   *     never fire the same request without waiting — that is what caused the ban), bounded.
   *   - After any response, if the per-minute remaining budget (X-RateLimit-Minute-Remaining)
   *     drops below a floor, pause proactively so we avoid producing a 429 in the first place.
   */
  private async request(url: string, label: string, cost = 1): Promise<any> {
    let netRetries = 0;
    for (let waits = 0; ; ) {
      await this.limiter.acquire(cost, this.sleep);
      let res: any;
      try {
        res = await this.fetchFn(url, { headers: { Authorization: `Bearer ${this.apiKey}` } });
      } catch (e) {
        if (!isTransientNetworkError(e) || netRetries >= NETWORK_RETRY_DELAYS_MS.length) throw e;
        const delay = NETWORK_RETRY_DELAYS_MS[netRetries++];
        console.warn(`[ppt] network error for ${label} (${(e as Error).message}) — retry ${netRetries}/${NETWORK_RETRY_DELAYS_MS.length} in ${delay / 1000}s`);
        await this.sleep(delay);
        continue;
      }
      if (res.status === 429) {
        waits++;
        if (waits > MAX_RETRY_AFTER_WAITS) throw new Error(`PPT 429 for ${label} (gave up after ${waits - 1} Retry-After waits)`);
        const ra = this.headerNum(res, "retry-after");
        await this.sleep(Number.isFinite(ra) && ra > 0 ? ra * 1000 : DEFAULT_BACKOFF_MS);
        continue;
      }
      if (!res.ok) throw new Error(`PPT ${res.status} for ${label}`);
      const remaining = this.headerNum(res, "x-ratelimit-minute-remaining");
      if (Number.isFinite(remaining) && remaining < MINUTE_REMAINING_FLOOR) {
        const ra = this.headerNum(res, "retry-after");
        await this.sleep(Number.isFinite(ra) && ra > 0 ? ra * 1000 : DEFAULT_BACKOFF_MS);
      }
      this.lastHeaders = {
        minuteLimit: this.headerNum(res, "x-ratelimit-minute-limit"),
        minuteRemaining: this.headerNum(res, "x-ratelimit-minute-remaining"),
        purchasedRemaining: this.headerNum(res, "x-ratelimit-purchased-remaining"),
        dailyRemaining: this.headerNum(res, "x-ratelimit-daily-remaining"),
      };
      return res;
    }
  }

  async getSetPrices(setName: string, opts: { graded?: boolean } = {}): Promise<PptPrice[]> {
    const params = new URLSearchParams({ set: setName, fetchAllInSet: "true" });
    if (opts.graded) params.set("includeEbay", "true");
    const res = await this.request(`${BASE}/cards?${params}`, `set ${setName}`);
    const body: any = await res.json();
    const cards: any[] = body.data ?? [];
    const perCard = opts.graded ? 2 : 1;
    this.budget.spend(cards.length * perCard);
    return cards.map((c) => ({
      tcgPlayerId: c.tcgPlayerId,
      setName: c.setName,
      cardNumber: String(c.cardNumber),
      name: c.name,
      raw: c.prices?.market ?? null,
      graded: parseLatestGraded(c.ebay),
    }));
  }

  /** Fetch every card in a PPT set with the fields needed for gap-fill (images + raw market).
   *  Price history is intentionally NOT requested here (see plan Global Constraints). */
  async getSetCards(setName: string): Promise<PptCard[]> {
    const params = new URLSearchParams({ set: setName, fetchAllInSet: "true" });
    const res = await this.request(`${BASE}/cards?${params}`, `set ${setName}`);
    const body: any = await res.json();
    const cards: any[] = body.data ?? [];
    this.budget.spend(cards.length);
    return cards.map((c) => ({
      externalCatalogId: c.externalCatalogId ?? null,
      cardNumber: String(c.cardNumber),
      name: c.name,
      imageUrl: c.imageCdnUrl800 ?? c.imageCdnUrl ?? null,
      marketUsd: typeof c.prices?.market === "number" ? c.prices.market : null,
    }));
  }

  /** Fetch weekly-ish price history for every card in a PPT set (one request). Reserves the
   *  WORST-CASE minute-call cost (`HISTORY_REQUEST_MINUTE_COST`, the 30-call cap) up front — NOT
   *  a value derived from `cardCountHint` — because PPT's true set size is unknown before the
   *  fetch and is billed on PPT's own card count, which can exceed our catalog's count for
   *  aliased/promo sets (see `HISTORY_REQUEST_MINUTE_COST`'s comment). This keeps the rolling
   *  <=45/min ceiling airtight (reserved cost is always >= real cost). Spends 2 credits/card
   *  (1 base + 1 includeHistory) against the daily budget separately, once the real card count is
   *  known. `cardCountHint` is retained in the signature for caller compatibility/telemetry only —
   *  it no longer affects the reserved cost. */
  async getSetHistory(setName: string, cardCountHint: number): Promise<PptHistoryCard[]> {
    const params = new URLSearchParams({
      set: setName, fetchAllInSet: "true", includeHistory: "true", days: "180", maxDataPoints: "26",
    });
    void cardCountHint; // retained for caller compatibility/telemetry; not used for cost — see above
    const res = await this.request(`${BASE}/cards?${params}`, `history ${setName}`, HISTORY_REQUEST_MINUTE_COST);
    const body: any = await res.json();
    const cards: any[] = body.data ?? [];
    this.budget.spend(cards.length * 2);
    return cards.map((c) => ({
      tcgPlayerId: c.tcgPlayerId ?? null,
      cardNumber: String(c.cardNumber),
      name: c.name,
      priceHistory: c.priceHistory ?? null,
    }));
  }

  /** One combined `/cards` call: raw + weekly history + latest graded (+ series if present) for a whole
   *  set. Reserves the worst-case minute-cost (30) — never a hint. Spends 3 credits/card (base+history+ebay). */
  async getSetEnrichment(setName: string): Promise<PptEnrichmentCard[]> {
    const params = new URLSearchParams({
      set: setName, fetchAllInSet: "true", includeHistory: "true", includeEbay: "true",
      days: "180", maxDataPoints: "26",
    });
    const res = await this.request(`${BASE}/cards?${params}`, `enrich ${setName}`, HISTORY_REQUEST_MINUTE_COST);
    const body: any = await res.json();
    const cards: any[] = body.data ?? [];
    this.budget.spend(cards.length * 3);
    return cards.map((c) => ({
      tcgPlayerId: c.tcgPlayerId ?? null,
      cardNumber: String(c.cardNumber),
      name: c.name,
      priceHistory: c.priceHistory ?? null,
      gradedLatest: parseLatestGraded(c.ebay),
      gradedSeries: parseGradedHistory(c.ebay),
      ebayRaw: c.ebay ?? null,
      pricesRaw: c.prices ?? null,
    }));
  }

  /** GemRate population for up to 50 tcgPlayerIds in one call. Reserves worst-case (30). Spends 2
   *  credits/card. A 403 (plan not entitled) propagates via request() and is NEVER retried. */
  async getPopulation(tcgPlayerIds: number[]): Promise<PopulationRow[]> {
    const ids = tcgPlayerIds.filter((n) => Number.isFinite(n)).slice(0, 50);
    if (ids.length === 0) return [];
    const csv = ids.join(",");
    const res = await this.request(`${BASE}/population?tcgPlayerIds=${csv}`, `population ${ids.length}`, HISTORY_REQUEST_MINUTE_COST);
    const body: any = await res.json();
    this.budget.spend(ids.length * 2);
    return parsePopulation(body);
  }

  /** Full PPT set list, paginated with limit/offset (paid tier rejects `page`). Routes through
   *  the rate-limit-safe request() path. Set metadata is not card-credit-billed. */
  async getAllSets(): Promise<{ name: string; slug: string; series: string; releaseDate: string | null }[]> {
    const LIMIT = 100;
    const out: { name: string; slug: string; series: string; releaseDate: string | null }[] = [];
    for (let offset = 0; offset < 5000; offset += LIMIT) {
      const res = await this.request(`${BASE}/sets?limit=${LIMIT}&offset=${offset}`, `sets@${offset}`);
      const body: any = await res.json();
      const rows: any[] = body.data ?? [];
      if (rows.length === 0) break;
      for (const s of rows) out.push({ name: s.name, slug: s.tcgPlayerId, series: s.series, releaseDate: s.releaseDate ?? null });
      if (rows.length < LIMIT) break;
    }
    return out;
  }
}
