import { verifyAppCheckToken } from "./appCheck";

export interface Env {
  BUCKET: R2Bucket;
  FIREBASE_PROJECT_NUMBER: string;
  FIREBASE_APP_ID: string;
}

const ALLOWED = /^(catalog|fingerprint)\/[A-Za-z0-9._\-\/]+$/;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

/// Backup origin for the catalog tiers and the scanner pack. Verifies a Firebase App Check token
/// and streams the object — nothing else. Deliberately stateless: no D1, no KV, no device store,
/// and no shared secret with catalog-server. The NAS keeps its own App Attest chain; this is a
/// second, independent one, so a fresh install can still authenticate while the NAS is down.
///
/// ponytail: no revocation list — a stolen App Check token is good until it expires (~1h). The
/// bytes are public-by-construction catalog data, so that is an accepted ceiling. Add a KV
/// denylist only if it ever stops being theoretical.
export async function handle(
  req: Request,
  env: Env,
  verify: (token: string, env: Env) => Promise<boolean> = verifyAppCheckToken,
): Promise<Response> {
  if (req.method !== "GET") return json(405, { error: "method_not_allowed" });

  const token = req.headers.get("X-Firebase-AppCheck");
  if (!token || !(await verify(token, env))) return json(401, { error: "unauthenticated" });

  // Decode first, THEN match: an encoded "%2E%2E%2F" must not sneak past the allow-list.
  let path: string;
  try { path = decodeURIComponent(new URL(req.url).pathname.slice(1)); }
  catch { return json(404, { error: "not_found" }); }
  if (!ALLOWED.test(path) || path.includes("..")) return json(404, { error: "not_found" });

  const obj = await env.BUCKET.get(path);
  if (!obj) return json(404, { error: "not_found" });
  return new Response(obj.body, {
    headers: { "content-type": "application/octet-stream", "cache-control": "no-store" },
  });
}

export default { fetch: (req: Request, env: Env) => handle(req, env) };
