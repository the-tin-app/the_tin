import { describe, it, expect, beforeAll, vi } from "vitest";
import { verifyAppCheckToken } from "../src/appCheck";
import type { Env } from "../src/index";

const PROJECT = "123456789012";
const APP = "1:123456789012:ios:abcdef";
const env = { BUCKET: {} as any, FIREBASE_PROJECT_NUMBER: PROJECT, FIREBASE_APP_ID: APP } satisfies Env;

let keyPair: CryptoKeyPair;
let jwks: { keys: unknown[] };

const b64url = (b: Uint8Array | string) => {
  const s = typeof b === "string" ? b : String.fromCharCode(...b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

async function sign(payload: object, header: object = { alg: "RS256", typ: "JWT", kid: "k1" }) {
  const signing = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const sig = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5", keyPair.privateKey, new TextEncoder().encode(signing)));
  return `${signing}.${b64url(sig)}`;
}

/** Stub fetch that always answers with our locally generated JWKS. */
const jwksFetch = (async () => new Response(JSON.stringify(jwks))) as unknown as typeof fetch;

/** Same stub, but counts how many times it was actually called — for pinning fetch counts. */
function countingJwksFetch() {
  let calls = 0;
  const fn = (async () => {
    calls++;
    return new Response(JSON.stringify(jwks));
  }) as unknown as typeof fetch;
  return { fetch: fn, count: () => calls };
}

const validPayload = () => ({
  iss: `https://firebaseappcheck.googleapis.com/${PROJECT}`,
  sub: APP,
  aud: [`projects/${PROJECT}`],
  exp: Math.floor(Date.now() / 1000) + 3600,
});

beforeAll(async () => {
  keyPair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true, ["sign", "verify"]);
  const jwk = await crypto.subtle.exportKey("jwk", keyPair.publicKey);
  jwks = { keys: [{ ...jwk, kid: "k1", alg: "RS256", use: "sig" }] };
});

describe("verifyAppCheckToken", () => {
  it("accepts a well-formed token", async () => {
    expect(await verifyAppCheckToken(await sign(validPayload()), env, jwksFetch)).toBe(true);
  });

  it("rejects an expired token", async () => {
    const p = { ...validPayload(), exp: Math.floor(Date.now() / 1000) - 1 };
    expect(await verifyAppCheckToken(await sign(p), env, jwksFetch)).toBe(false);
  });

  it("rejects a token for another project", async () => {
    const p = { ...validPayload(), iss: "https://firebaseappcheck.googleapis.com/999" };
    expect(await verifyAppCheckToken(await sign(p), env, jwksFetch)).toBe(false);
  });

  it("rejects a token whose aud omits our project", async () => {
    const p = { ...validPayload(), aud: ["projects/999"] };
    expect(await verifyAppCheckToken(await sign(p), env, jwksFetch)).toBe(false);
  });

  it("rejects a token for a different app id", async () => {
    const p = { ...validPayload(), sub: "1:123456789012:android:zzz" };
    expect(await verifyAppCheckToken(await sign(p), env, jwksFetch)).toBe(false);
  });

  it("rejects a tampered payload", async () => {
    const t = await sign(validPayload());
    const [h, , s] = t.split(".");
    const forged = b64url(JSON.stringify({ ...validPayload(), sub: "evil" }));
    expect(await verifyAppCheckToken(`${h}.${forged}.${s}`, env, jwksFetch)).toBe(false);
  });

  it("rejects an unsigned / alg:none token", async () => {
    const t = await sign(validPayload(), { alg: "none", typ: "JWT", kid: "k1" });
    expect(await verifyAppCheckToken(t, env, jwksFetch)).toBe(false);
  });

  it("rejects garbage", async () => {
    expect(await verifyAppCheckToken("not.a.jwt", env, jwksFetch)).toBe(false);
    expect(await verifyAppCheckToken("", env, jwksFetch)).toBe(false);
  });

  it("rejects when the JWKS has no matching kid", async () => {
    const t = await sign(validPayload(), { alg: "RS256", typ: "JWT", kid: "other" });
    expect(await verifyAppCheckToken(t, env, jwksFetch)).toBe(false);
  });
});

// Each case here needs a cold module (cache = null, no prior forced refetch), because the
// counts asserted only mean anything against a fresh isolate. vi.resetModules() + a dynamic
// re-import gets a clean copy of the module-scope cache and throttle timestamp.
describe("verifyAppCheckToken — JWKS refetch throttling (finding 1)", () => {
  it("does a cold fetch plus exactly one forced refetch on an unrecognized kid", async () => {
    vi.resetModules();
    const { verifyAppCheckToken: verify } = await import("../src/appCheck");
    const { fetch: fn, count } = countingJwksFetch();

    const t = await sign(validPayload(), { alg: "RS256", typ: "JWT", kid: "nope-1" });
    expect(await verify(t, env, fn)).toBe(false);
    expect(count()).toBe(2); // 1 cold-cache fetch + 1 forced refetch
  });

  it("does the same for a different unrecognized kid (guards the ?? against becoming a loop)", async () => {
    vi.resetModules();
    const { verifyAppCheckToken: verify } = await import("../src/appCheck");
    const { fetch: fn, count } = countingJwksFetch();

    const t = await sign(validPayload(), { alg: "RS256", typ: "JWT", kid: "nope-2" });
    expect(await verify(t, env, fn)).toBe(false);
    expect(count()).toBe(2);
  });

  it("does not force a second refetch within the throttle window", async () => {
    vi.resetModules();
    const { verifyAppCheckToken: verify } = await import("../src/appCheck");
    const { fetch: fn, count } = countingJwksFetch();

    const t1 = await sign(validPayload(), { alg: "RS256", typ: "JWT", kid: "nope-a" });
    expect(await verify(t1, env, fn)).toBe(false);
    expect(count()).toBe(2);

    // A second, distinct unrecognized kid arrives immediately after — still inside the
    // 5-minute floor, so this must add zero fetches, and must still fail closed (a rejection,
    // not a bypass) rather than silently retrying.
    const t2 = await sign(validPayload(), { alg: "RS256", typ: "JWT", kid: "nope-b" });
    expect(await verify(t2, env, fn)).toBe(false);
    expect(count()).toBe(2);
  });

  it("still verifies a legitimate token after an unrecognized-kid miss", async () => {
    vi.resetModules();
    const { verifyAppCheckToken: verify } = await import("../src/appCheck");
    const { fetch: fn, count } = countingJwksFetch();

    const bad = await sign(validPayload(), { alg: "RS256", typ: "JWT", kid: "nope-c" });
    expect(await verify(bad, env, fn)).toBe(false);
    expect(count()).toBe(2);

    // The happy path is served from the cache the cold fetch already populated — the throttle
    // must not touch it, so no additional fetch and a true result.
    const good = await sign(validPayload());
    expect(await verify(good, env, fn)).toBe(true);
    expect(count()).toBe(2);
  });
});
