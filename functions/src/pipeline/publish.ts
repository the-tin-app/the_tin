import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { createHash } from "node:crypto";

export interface StoragePort {
  save(path: string, data: Buffer, contentType: string): Promise<void>;
}

export interface Manifest {
  version: number; path: string; sha256: string; sizeBytes: number; generatedAt: string;
}

export async function publishCatalog(dbPath: string, version: number, storage: StoragePort, now: Date): Promise<Manifest> {
  const gz = gzipSync(readFileSync(dbPath));
  const path = `catalog/catalog-v${version}.sqlite.gz`;
  await storage.save(path, gz, "application/gzip");
  const manifest: Manifest = {
    version, path,
    sha256: createHash("sha256").update(gz).digest("hex"),
    sizeBytes: gz.length,
    generatedAt: now.toISOString(),
  };
  await storage.save("catalog/manifest.json", Buffer.from(JSON.stringify(manifest)), "application/json");
  return manifest;
}
