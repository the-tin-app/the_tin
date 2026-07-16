import { readFileSync } from "node:fs";
import { createServer } from "./server";
import { openDeviceStore } from "./db";
import { createChallengeStore } from "./challenges";

const port = Number(process.env.PORT ?? 8080);
const catalogDir = process.env.CATALOG_DIR ?? "/data/catalog";
const fingerprintDir = process.env.FINGERPRINT_DIR ?? "/data/fingerprint";
const dbPath = process.env.DEVICE_DB_PATH ?? "/data/devices.sqlite";
const sessionSecret = process.env.SESSION_SECRET;
const appId = process.env.APP_ID; // "<TEAM_ID>.<BUNDLE_ID>"
const rootCaPath = process.env.APPLE_ROOT_CA_PATH;
const environment = process.env.APP_ATTEST_ENVIRONMENT; // "development" | "production"

if (!sessionSecret || !appId || !rootCaPath) {
  throw new Error("SESSION_SECRET, APP_ID, and APPLE_ROOT_CA_PATH env vars are required");
}
if (environment !== "development" && environment !== "production") {
  throw new Error('APP_ATTEST_ENVIRONMENT must be "development" or "production"');
}

createServer({
  deviceStore: openDeviceStore(dbPath),
  challengeStore: createChallengeStore(120),
  sessionSecret,
  appId,
  trustedRootPem: readFileSync(rootCaPath, "utf8"),
  catalogDir,
  fingerprintDir,
  environment,
}).listen(port, () => console.log(`catalog-server listening on :${port}`));
