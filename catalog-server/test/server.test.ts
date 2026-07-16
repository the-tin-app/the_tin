import { describe, it, expect, beforeEach, afterEach } from "vitest";
import http from "node:http";
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash, generateKeyPairSync, sign as cryptoSign } from "node:crypto";
import { encode as cborEncode } from "cbor";
import { createServer, ServerConfig } from "../src/server";
import { openDeviceStore } from "../src/db";
import { createChallengeStore } from "../src/challenges";

const APP_ID = "TESTTEAM.ai.reyes.thetin";

function buildAuthData(rpIdHash: Buffer, counter: number, attested?: { aaguid: Buffer; credentialId: Buffer; cosePublicKey: Buffer }) {
  const flags = attested ? 0x40 : 0x00;
  const counterBuf = Buffer.alloc(4); counterBuf.writeUInt32BE(counter);
  const parts = [rpIdHash, Buffer.from([flags]), counterBuf];
  if (attested) {
    const lenBuf = Buffer.alloc(2); lenBuf.writeUInt16BE(attested.credentialId.length);
    parts.push(attested.aaguid, lenBuf, attested.credentialId, attested.cosePublicKey);
  }
  return Buffer.concat(parts);
}

function jsonRequest(server: http.Server, method: string, path: string, body?: unknown, headers: Record<string, string> = {}): Promise<{ status: number; body: any }> {
  return new Promise((resolve, reject) => {
    server.listen(0, () => {
      const { port } = server.address() as { port: number };
      const req = http.request({ host: "127.0.0.1", port, method, path, headers: { "content-type": "application/json", ...headers } }, (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => {
          server.close();
          let parsed: any = null;
          try { parsed = data ? JSON.parse(data) : null; } catch { parsed = data; }
          resolve({ status: res.statusCode!, body: parsed });
        });
      });
      req.on("error", reject);
      if (body !== undefined) req.write(JSON.stringify(body));
      req.end();
    });
  });
}

describe("catalog-server routes", () => {
  let dir: string;
  let fpDir: string;
  let config: ServerConfig;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "catalog-server-"));
    writeFileSync(join(dir, "manifest.json"), JSON.stringify({ version: 1 }));
    writeFileSync(join(dir, "core-v1.sqlite.gz"), Buffer.from("fake-gzip-bytes"));
    fpDir = mkdtempSync(join(tmpdir(), "fingerprint-"));
    writeFileSync(join(fpDir, "manifest.json"), JSON.stringify({ version: 1, fpVersion: 3 }));
    config = {
      deviceStore: openDeviceStore(join(dir, "devices.sqlite")),
      challengeStore: createChallengeStore(60),
      sessionSecret: "test-secret",
      appId: APP_ID,
      trustedRootPem: "unused-until-attest-test",
      catalogDir: dir,
      fingerprintDir: fpDir,
      environment: "production",
    };
  });

  afterEach(() => { rmSync(dir, { recursive: true, force: true }); rmSync(fpDir, { recursive: true, force: true }); });

  it("GET /health returns ok", async () => {
    const { status, body } = await jsonRequest(createServer(config), "GET", "/health");
    expect(status).toBe(200);
    expect(body).toEqual({ ok: true });
  });

  it("GET /challenge issues a nonce", async () => {
    const { status, body } = await jsonRequest(createServer(config), "GET", "/challenge");
    expect(status).toBe(200);
    expect(typeof body.nonce).toBe("string");
  });

  it("full attest -> download round trip with a REAL Apple attestation", async () => {
    // Drives the genuine attestation captured from a physical iPhone through the real server path:
    // POST /attest (EC cert-chain verification against Apple's real root) -> session token ->
    // gated GET /catalog. Configured for the fixture's actual appId + development environment.
    const fixture = JSON.parse(readFileSync(join(__dirname, "fixtures/real-attestation.json"), "utf8"));
    config.appId = "GXP2X83CRN.ai.reyes.thetin";
    config.environment = "development";
    config.trustedRootPem = readFileSync(join(__dirname, "fixtures/apple-root-ca.pem"), "utf8");
    // The captured nonce was already consumed by the live server; hand it back as valid once here.
    config.challengeStore = { issue: () => "unused", consume: (n) => n === fixture.nonce };

    const attestRes = await jsonRequest(createServer(config), "POST", "/attest", {
      keyId: fixture.keyId,
      nonce: fixture.nonce,
      attestationObject: fixture.attestationObject,
    });
    expect(attestRes.status).toBe(200);
    expect(typeof attestRes.body.sessionToken).toBe("string");

    const downloadRes = await jsonRequest(createServer(config), "GET", "/catalog/manifest.json", undefined, { authorization: `Bearer ${attestRes.body.sessionToken}` });
    expect(downloadRes.status).toBe(200);

    // Same session token also gates the scanner pack, served alongside the catalog under /fingerprint/.
    const fpRes = await jsonRequest(createServer(config), "GET", "/fingerprint/manifest.json", undefined, { authorization: `Bearer ${attestRes.body.sessionToken}` });
    expect(fpRes.status).toBe(200);
    expect(fpRes.body.fpVersion).toBe(3);
  });

  it("rejects /catalog/* and /fingerprint/* without a valid session", async () => {
    expect((await jsonRequest(createServer(config), "GET", "/catalog/manifest.json")).status).toBe(401);
    expect((await jsonRequest(createServer(config), "GET", "/fingerprint/manifest.json")).status).toBe(401);
  });

  it("POST /assert with a valid assertion returns a new session token", async () => {
    // Bypass /attest and register a device directly, per Task 6 Step 6 review note: verifyAssertion
    // needs the signing keypair to match the device's stored public key, and constructing that
    // match through the RSA-leaf /attest fixture is awkward — a real EC keypair registered
    // directly still exercises the /assert ROUTE's wiring (nonce consumption, device lookup,
    // verifyAssertion call, counter bump, session issuance), which is what had zero coverage.
    const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const publicKeyDer = publicKey.export({ format: "der", type: "spki" }) as Buffer;
    const keyId = createHash("sha256").update(publicKeyDer).digest();
    config.deviceStore.upsertDevice({ keyId: keyId.toString("base64url"), publicKeyDer, counter: 3, firstSeen: new Date().toISOString() });

    const server1 = createServer(config);
    const challengeRes = await jsonRequest(server1, "GET", "/challenge");
    const nonce = Buffer.from(challengeRes.body.nonce, "base64url");

    const rpIdHash = createHash("sha256").update(APP_ID).digest();
    const authenticatorData = buildAuthData(rpIdHash, 4);
    const clientDataHash = createHash("sha256").update(nonce).digest();
    const signedData = createHash("sha256").update(Buffer.concat([authenticatorData, clientDataHash])).digest();
    const signature = cryptoSign("sha256", signedData, privateKey);
    const assertionObject = cborEncode(new Map<string, unknown>([["signature", signature], ["authenticatorData", authenticatorData]]));

    const server2 = createServer(config);
    const assertRes = await jsonRequest(server2, "POST", "/assert", {
      keyId: keyId.toString("base64url"),
      nonce: challengeRes.body.nonce,
      assertionObject: assertionObject.toString("base64url"),
    });
    expect(assertRes.status).toBe(200);
    expect(typeof assertRes.body.sessionToken).toBe("string");
  });

  it("POST /attest with an oversized body is rejected with 413 and no error detail leak", async () => {
    const { status, body } = await jsonRequest(createServer(config), "POST", "/attest", {
      nonce: "irrelevant",
      keyId: "irrelevant",
      attestationObject: "x".repeat(70_000),
    });
    expect(status).toBe(413);
    expect(body).toEqual({ error: "payload_too_large" });
  });

  it("POST /attest with a bad attestation returns a generic error, not the raw verification message", async () => {
    const server1 = createServer(config);
    const challengeRes = await jsonRequest(server1, "GET", "/challenge");

    const server2 = createServer(config);
    const attestRes = await jsonRequest(server2, "POST", "/attest", {
      keyId: Buffer.from("bogus").toString("base64url"),
      nonce: challengeRes.body.nonce,
      attestationObject: Buffer.from("not a real cbor attestation object").toString("base64url"),
    });
    expect(attestRes.status).toBe(400);
    expect(attestRes.body).toEqual({ error: "attestation_failed" });
  });
});
