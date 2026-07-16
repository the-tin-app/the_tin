export type NowFn = () => number;
export type SleepFn = (ms: number) => Promise<void>;

/**
 * Cost-aware rolling-window rate limiter. Guarantees the sum of admitted costs in any trailing
 * `windowMs` never exceeds `maxPerWindow`. Used to hold PPT minute-calls at <= 45/min — a
 * `fetchAllInSet` request costs `min(30, ceil(cards/10))` minute-calls. Since PPT bills on ITS
 * card count (which our alias/promo set mappings can under-count), history requests reserve the
 * worst-case 30-call cap (see `HISTORY_REQUEST_MINUTE_COST`) rather than an estimate. The limiter's
 * guarantee is on RESERVED cost, and reserved >= real, so real usage never exceeds the ceiling.
 */
export class MinuteRateLimiter {
  private readonly window: { t: number; cost: number }[] = [];
  constructor(
    private readonly maxPerWindow = 45,
    private readonly now: NowFn = Date.now,
    private readonly windowMs = 60_000,
  ) {}

  private prune(t: number): void {
    const cutoff = t - this.windowMs;
    while (this.window.length > 0 && this.window[0].t <= cutoff) this.window.shift();
  }

  private sum(): number {
    return this.window.reduce((a, e) => a + e.cost, 0);
  }

  /** Block until `cost` fits in the trailing window, then reserve it. */
  async acquire(cost: number, sleep: SleepFn): Promise<void> {
    if (cost > this.maxPerWindow) {
      throw new Error(`rate-limiter: single cost ${cost} exceeds max ${this.maxPerWindow}`);
    }
    for (;;) {
      const t = this.now();
      this.prune(t);
      if (this.sum() + cost <= this.maxPerWindow) {
        this.window.push({ t, cost });
        return;
      }
      const oldest = this.window[0];
      const waitMs = oldest.t + this.windowMs - t;
      await sleep(waitMs > 0 ? waitMs : 1);
    }
  }
}
