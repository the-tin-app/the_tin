import { describe, it, expect } from "vitest";
import { handle, type Env } from "../src/index";

const env = { BUCKET: {} as any, FIREBASE_PROJECT_NUMBER: "1", FIREBASE_APP_ID: "app" } satisfies Env;
const yes = async () => true;
const no = async () => false;

function bucketWith(objects: Record<string, string>) {
  return {
    get: async (key: string) =>
      key in objects ? { body: objects[key] as unknown as ReadableStream } : null,
  } as any;
}

describe("handle", () => {
  it("401s with no App Check header", async () => {
    const res = await handle(new Request("https://x/catalog/manifest.json"), env, no);
    expect(res.status).toBe(401);
  });

  it("401s when the token does not verify", async () => {
    const req = new Request("https://x/catalog/manifest.json", { headers: { "X-Firebase-AppCheck": "bad" } });
    expect((await handle(req, env, no)).status).toBe(401);
  });

  it("404s a path outside catalog/ and fingerprint/ even with a good token", async () => {
    const req = new Request("https://x/devices.sqlite", { headers: { "X-Firebase-AppCheck": "ok" } });
    expect((await handle(req, env, yes)).status).toBe(404);
  });

  it("404s a literal .. path (URL parser normalizes it before we see it)", async () => {
    const req = new Request("https://x/catalog/../devices.sqlite", { headers: { "X-Firebase-AppCheck": "ok" } });
    expect((await handle(req, env, yes)).status).toBe(404);
  });

  it("refuses percent-encoded path traversal", async () => {
    const req = new Request("https://x/catalog/%2E%2E%2Ffingerprint%2Fsecret", {
      headers: { "X-Firebase-AppCheck": "ok" },
    });
    expect((await handle(req, env, yes)).status).toBe(404);
  });

  it("405s a non-GET", async () => {
    const req = new Request("https://x/catalog/manifest.json", {
      method: "PUT", headers: { "X-Firebase-AppCheck": "ok" },
    });
    expect((await handle(req, env, yes)).status).toBe(405);
  });

  it("404s an object that is not in the bucket", async () => {
    const req = new Request("https://x/catalog/casual-v99.sqlite.gz", { headers: { "X-Firebase-AppCheck": "ok" } });
    const res = await handle(req, { ...env, BUCKET: bucketWith({}) }, yes);
    expect(res.status).toBe(404);
  });

  it("streams an object that is present", async () => {
    const req = new Request("https://x/catalog/manifest.json", { headers: { "X-Firebase-AppCheck": "ok" } });
    const res = await handle(req, { ...env, BUCKET: bucketWith({ "catalog/manifest.json": "{}" }) }, yes);
    expect(res.status).toBe(200);
  });
});
