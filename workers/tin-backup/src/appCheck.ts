import type { Env } from "./index";

const JWKS_URL = "https://firebaseappcheck.googleapis.com/v1/jwks";
const JWKS_TTL_MS = 60 * 60 * 1000;
// Google rotates keys on an hourly scale, so this doesn't hurt the refetch's actual purpose —
// it only stops an attacker-controlled `kid` from turning into an unmetered fetch amplifier
// (a well-formed-but-unsigned header reaches the refetch before the signature is ever checked).
const FORCED_REFETCH_FLOOR_MS = 5 * 60 * 1000;

// ponytail: module-scope cache, so it lives as long as the isolate and no KV is involved.
// Worst case a cold isolate makes one extra subrequest.
let cache: { keys: any[]; at: number } | null = null;
let lastForcedRefetchAt = 0;

function b64urlToBytes(s: string): Uint8Array {
  const pad = s.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(pad + "=".repeat((4 - (pad.length % 4)) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

function jsonPart(s: string): any {
  return JSON.parse(new TextDecoder().decode(b64urlToBytes(s)));
}

async function jwks(fetchFn: typeof fetch, force: boolean): Promise<any[]> {
  if (!force && cache && Date.now() - cache.at < JWKS_TTL_MS) return cache.keys;
  if (force) {
    // Floor the forced path only: an unrecognised kid needs no valid signature to reach here,
    // so without this an unauthenticated caller converts request volume 1:1 into subrequests
    // against Google — and a Google-side throttle then fails every legitimate request closed.
    // A second miss inside the window is still a real rejection, just without a wasted refetch.
    if (cache && Date.now() - lastForcedRefetchAt < FORCED_REFETCH_FLOOR_MS) return cache.keys;
    lastForcedRefetchAt = Date.now();
  }
  const res = await fetchFn(JWKS_URL);
  if (!res.ok) throw new Error(`jwks ${res.status}`);
  const keys = ((await res.json()) as { keys: any[] }).keys ?? [];
  cache = { keys, at: Date.now() };
  return keys;
}

/// Verify a Firebase App Check token per Google's documented backend steps. Returns a boolean —
/// the caller only ever needs "may this request read bytes", and a thrown error here would leak
/// the difference between a bad token and a JWKS outage into the response.
export async function verifyAppCheckToken(
  token: string,
  env: Env,
  fetchFn: typeof fetch = fetch,
): Promise<boolean> {
  try {
    const [h, p, s] = token.split(".");
    if (!h || !p || !s) return false;

    const header = jsonPart(h);
    if (header.typ !== "JWT" || header.alg !== "RS256" || !header.kid) return false;

    // Unknown kid → refetch once: Google rotates keys and a stale cache must not fail closed
    // forever. A second miss is a real rejection.
    let key = (await jwks(fetchFn, false)).find((k) => k.kid === header.kid)
           ?? (await jwks(fetchFn, true)).find((k) => k.kid === header.kid);
    if (!key) return false;

    const pub = await crypto.subtle.importKey(
      "jwk", key, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
    const ok = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5", pub, b64urlToBytes(s), new TextEncoder().encode(`${h}.${p}`));
    if (!ok) return false;

    const claims = jsonPart(p);
    const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    return claims.iss === `https://firebaseappcheck.googleapis.com/${env.FIREBASE_PROJECT_NUMBER}`
      && aud.includes(`projects/${env.FIREBASE_PROJECT_NUMBER}`)
      && claims.sub === env.FIREBASE_APP_ID
      && typeof claims.exp === "number"
      && claims.exp > Math.floor(Date.now() / 1000);
  } catch {
    return false;
  }
}
