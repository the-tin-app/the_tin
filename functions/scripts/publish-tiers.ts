import Database from "better-sqlite3";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { mkdirSync, copyFileSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { publishCatalog, StoragePort } from "../src/pipeline/publish";
import { getStorage } from "firebase-admin/storage";
import { initializeApp, applicationDefault, getApps } from "firebase-admin/app";

// Only these two tables are ever physically dropped: they are the only tables the iOS app never
// queries (verified against ios/TCGApp/Sources/**). Every other table the app reads stays present.
const BACKEND_ONLY_TABLES = ["price_history_cond", "graded_history"];

export function splitTiers(sourceDbPath: string, outDir: string): {
  casualPath: string; averagePath: string; expertPath: string;
} {
  mkdirSync(outDir, { recursive: true });
  const casualPath = join(outDir, "casual.sqlite");
  const averagePath = join(outDir, "average.sqlite");
  const expertPath = join(outDir, "expert.sqlite");

  // expert = full DB, untouched.
  copyFileSync(sourceDbPath, expertPath);

  // average = full minus the two backend-only history tables.
  copyFileSync(sourceDbPath, averagePath);
  const average = new Database(averagePath);
  for (const t of BACKEND_ONLY_TABLES) average.exec(`DROP TABLE IF EXISTS "${t}"`);
  average.exec("VACUUM");
  average.close();

  // casual = average, and additionally EMPTY price_history (keep the table so the app's sparkline
  // query returns no rows instead of failing on a missing table).
  copyFileSync(averagePath, casualPath);
  const casual = new Database(casualPath);
  casual.exec('DELETE FROM price_history');
  casual.exec("VACUUM");
  casual.close();

  return { casualPath, averagePath, expertPath };
}

export interface TierEntry { path: string; sha256: string; sizeBytes: number }

export interface NasManifest {
  version: number;
  generatedAt: string;
  tiers: { casual: TierEntry; average: TierEntry; expert: TierEntry };
}

export async function publishTiers(opts: {
  sourceDbPath: string; version: number; nasDir: string;
  firebaseStorage: StoragePort; now: Date; publishToFirebase: boolean;
}): Promise<NasManifest> {
  const { casualPath, averagePath, expertPath } = splitTiers(opts.sourceDbPath, join(opts.nasDir, "_work"));
  const catalogDir = join(opts.nasDir, "catalog");
  mkdirSync(catalogDir, { recursive: true });

  const writeTier = (tier: string, dbPath: string): TierEntry => {
    const gz = gzipSync(readFileSync(dbPath));
    const path = `${tier}-v${opts.version}.sqlite.gz`;
    writeFileSync(join(catalogDir, path), gz);
    return { path, sha256: createHash("sha256").update(gz).digest("hex"), sizeBytes: gz.length };
  };

  const manifest: NasManifest = {
    version: opts.version,
    generatedAt: opts.now.toISOString(),
    tiers: {
      casual: writeTier("casual", casualPath),
      average: writeTier("average", averagePath),
      expert: writeTier("expert", expertPath),
    },
  };
  writeFileSync(join(catalogDir, "manifest.json"), JSON.stringify(manifest));

  // Firebase backup: casual tier only, via the unchanged publishCatalog() (flat manifest + flat
  // catalog-vN.sqlite.gz). It gzips the SAME casual sqlite with the same deterministic gzip, so its
  // bytes are sha256-identical to the NAS casual artifact — asserted in publish-tiers.test.ts.
  if (opts.publishToFirebase) {
    await publishCatalog(casualPath, opts.version, opts.firebaseStorage, opts.now);
  }

  // The uncompressed split sqlites are already gzipped into catalogDir above; nothing else needs
  // the scratch copies, so clean them up (~850MB uncompressed across the three tiers).
  rmSync(join(opts.nasDir, "_work"), { recursive: true, force: true });

  return manifest;
}

// CLI: publish the three tiers from an already-built sqlite.
//   npx tsx scripts/publish-tiers.ts <sourceDbPath> <version> <nasDir> [--firebase]
// --firebase also pushes the casual tier to gs://$FIREBASE_STORAGE_BUCKET/catalog via
// applicationDefault creds — set FIREBASE_STORAGE_BUCKET to your own project's bucket.
const BUCKET = process.env.FIREBASE_STORAGE_BUCKET;

class BucketStorage implements StoragePort {
  async save(path: string, data: Buffer, contentType: string) {
    if (getApps().length === 0) initializeApp({ credential: applicationDefault(), storageBucket: BUCKET });
    await getStorage().bucket().file(path).save(data, { contentType });
  }
}

async function main() {
  const [sourceDbPath, versionArg, nasDir] = process.argv.slice(2);
  const publishToFirebase = process.argv.includes("--firebase");
  if (!sourceDbPath || !versionArg || !nasDir) {
    console.error("usage: publish-tiers.ts <sourceDbPath> <version> <nasDir> [--firebase]");
    process.exit(1);
  }
  if (publishToFirebase && !BUCKET) {
    console.error("--firebase requires FIREBASE_STORAGE_BUCKET (e.g. <project>.firebasestorage.app)");
    process.exit(1);
  }
  const m = await publishTiers({
    sourceDbPath, version: Number(versionArg), nasDir,
    firebaseStorage: new BucketStorage(), now: new Date(), publishToFirebase,
  });
  for (const tier of ["casual", "average", "expert"] as const) {
    const e = m.tiers[tier];
    console.log(`  ${tier.padEnd(8)} ${e.path}  ${(e.sizeBytes / 1e6).toFixed(1)} MB gz  sha ${e.sha256.slice(0, 12)}…`);
  }
  console.log(`  firebase(casual): ${publishToFirebase ? "PUBLISHED (sha matches NAS casual)" : "SKIPPED"}`);
}

if (require.main === module) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
