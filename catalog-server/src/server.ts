import http from "node:http";
import { createReadStream, existsSync, statSync } from "node:fs";
import { join, normalize } from "node:path";
import { DeviceStore } from "./db";
import { ChallengeStore } from "./challenges";
import { issueSessionToken, verifySessionToken } from "./session";
import { verifyAttestation, verifyAssertion } from "./appAttest";

export interface ServerConfig {
  deviceStore: DeviceStore;
  challengeStore: ChallengeStore;
  sessionSecret: string;
  appId: string;
  trustedRootPem: string;
  catalogDir: string;
  fingerprintDir: string;
  environment: "development" | "production";
}

const SESSION_TTL_SECONDS = 30 * 24 * 60 * 60;
const MAX_BODY_BYTES = 64 * 1024;

function readJsonBody(req: http.IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    let data = "";
    let bytes = 0;
    req.on("data", (c) => {
      bytes += c.length;
      if (bytes > MAX_BODY_BYTES) {
        // ponytail: don't req.destroy() here — req/res share one socket, so destroying it would
        // also kill our ability to write the 413 response below. Just stop buffering (bounds
        // memory) and let Node drain+discard the rest of the body harmlessly.
        if (data.length > 0) data = "";
        reject(new Error("payload_too_large"));
        return;
      }
      data += c;
    });
    req.on("end", () => {
      try { resolve(data ? JSON.parse(data) : {}); } catch (e) { reject(e); }
    });
    req.on("error", reject);
  });
}

function sendJson(res: http.ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

/// Serve a static file under `baseDir` for an authed GET at `<prefix><relative>`. Shared by the
/// catalog and fingerprint routes — identical App Attest session gate + path-traversal guard +
/// streamed body. Session must already be verified by the caller.
function serveStatic(req: http.IncomingMessage, res: http.ServerResponse, prefix: string, baseDir: string) {
  const relative = normalize(decodeURIComponent(req.url!.slice(prefix.length))).replace(/^(\.\.[/\\])+/, "");
  const filePath = join(baseDir, relative);
  if (!filePath.startsWith(baseDir) || !existsSync(filePath) || !statSync(filePath).isFile()) {
    return sendJson(res, 404, { error: "not_found" });
  }
  res.writeHead(200, { "content-type": "application/octet-stream" });
  createReadStream(filePath)
    .on("error", (err) => {
      console.error("static file read failed:", err.message);
      if (!res.headersSent) sendJson(res, 500, { error: "read_failed" });
      else res.destroy();
    })
    .pipe(res);
}

export function createServer(config: ServerConfig): http.Server {
  return http.createServer(async (req, res) => {
    try {
      if (req.method === "GET" && req.url === "/health") {
        return sendJson(res, 200, { ok: true });
      }

      if (req.method === "GET" && req.url === "/challenge") {
        return sendJson(res, 200, { nonce: config.challengeStore.issue() });
      }

      if (req.method === "POST" && req.url === "/attest") {
        let body: any;
        try { body = await readJsonBody(req); } catch (e) {
          if ((e as Error).message === "payload_too_large") return sendJson(res, 413, { error: "payload_too_large" });
          throw e;
        }
        if (!config.challengeStore.consume(body.nonce)) return sendJson(res, 401, { error: "invalid_or_expired_nonce" });
        // Dev-only: capture a real Apple attestation body to disk for use as a test fixture.
        // Inert in production (env unset).
        if (process.env.CAPTURE_ATTEST_PATH) {
          try {
            require("node:fs").writeFileSync(process.env.CAPTURE_ATTEST_PATH, JSON.stringify(body, null, 2));
            console.log(`captured attestation body -> ${process.env.CAPTURE_ATTEST_PATH}`);
          } catch (e) { console.error("capture failed:", (e as Error).message); }
        }
        try {
          const keyId = Buffer.from(body.keyId, "base64url");
          const attestationObject = Buffer.from(body.attestationObject, "base64url");
          const nonce = Buffer.from(body.nonce, "base64url");
          const { publicKeyDer } = verifyAttestation({ attestationObject, keyId, nonce, appId: config.appId, trustedRootPem: config.trustedRootPem, environment: config.environment });
          config.deviceStore.upsertDevice({ keyId: body.keyId, publicKeyDer, counter: 0, firstSeen: new Date().toISOString() });
          const sessionToken = issueSessionToken(config.sessionSecret, body.keyId, SESSION_TTL_SECONDS);
          return sendJson(res, 200, { sessionToken });
        } catch (e) {
          console.error("attestation verification failed:", (e as Error).message);
          return sendJson(res, 400, { error: "attestation_failed" });
        }
      }

      if (req.method === "POST" && req.url === "/assert") {
        let body: any;
        try { body = await readJsonBody(req); } catch (e) {
          if ((e as Error).message === "payload_too_large") return sendJson(res, 413, { error: "payload_too_large" });
          throw e;
        }
        if (!config.challengeStore.consume(body.nonce)) return sendJson(res, 401, { error: "invalid_or_expired_nonce" });
        const device = config.deviceStore.getDevice(body.keyId);
        if (!device) return sendJson(res, 401, { error: "unknown_device" });
        try {
          const assertionObject = Buffer.from(body.assertionObject, "base64url");
          const nonce = Buffer.from(body.nonce, "base64url");
          const { newCounter } = verifyAssertion({ assertionObject, nonce, appId: config.appId, storedPublicKeyDer: device.publicKeyDer, storedCounter: device.counter });
          config.deviceStore.bumpCounter(body.keyId, newCounter);
          const sessionToken = issueSessionToken(config.sessionSecret, body.keyId, SESSION_TTL_SECONDS);
          return sendJson(res, 200, { sessionToken });
        } catch (e) {
          console.error("assertion verification failed:", (e as Error).message);
          return sendJson(res, 400, { error: "assertion_failed" });
        }
      }

      // Static download routes: catalog (tiered sqlite) and fingerprint (scanner pack). Both are
      // App Attest session-gated and stream files from their own data dir.
      const staticRoute =
        req.url?.startsWith("/catalog/") ? { prefix: "/catalog/", dir: config.catalogDir } :
        req.url?.startsWith("/fingerprint/") ? { prefix: "/fingerprint/", dir: config.fingerprintDir } :
        null;
      if (req.method === "GET" && staticRoute) {
        const auth = req.headers.authorization;
        const token = auth?.startsWith("Bearer ") ? auth.slice("Bearer ".length) : null;
        const session = token ? verifySessionToken(config.sessionSecret, token) : null;
        if (!session) return sendJson(res, 401, { error: "unauthenticated" });
        return serveStatic(req, res, staticRoute.prefix, staticRoute.dir);
      }

      sendJson(res, 404, { error: "not_found" });
    } catch (e) {
      sendJson(res, 400, { error: (e as Error).message });
    }
  });
}
