// functions/src/pipeline/overnight-halt.ts
/** True iff a sweep stopReason was a PPT rate-limit / ban (429 or 403) — the one class of stop that must NOT auto-resume. */
export function isRateLimitStop(stopReason: string | undefined): boolean {
  return /PPT (429|403)/.test(stopReason ?? "");
}

/** Decide what a live (non --done-check) run should do given a persisted halt flag + the operator's clear-env.
 *  - not halted            -> "proceed"
 *  - halted, clear env set  -> "clear"    (operator explicitly clearing after the ban window)
 *  - halted, no clear env   -> "refuse"   (do NOT touch the API) */
export function haltGate(halted: boolean, clearEnv: string | undefined): "proceed" | "clear" | "refuse" {
  if (!halted) return "proceed";
  return clearEnv === "1" ? "clear" : "refuse";
}
