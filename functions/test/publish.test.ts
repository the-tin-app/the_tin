import { describe, it, expect } from "vitest";
import { gunzipSync } from "node:zlib";
import { createHash } from "node:crypto";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { publishCatalog, StoragePort } from "../src/pipeline/publish";

class MemStorage implements StoragePort {
  files = new Map<string, { data: Buffer; contentType: string }>();
  async save(path: string, data: Buffer, contentType: string) { this.files.set(path, { data, contentType }); }
}

describe("publishCatalog", () => {
  it("uploads gzipped artifact plus manifest with matching sha256", async () => {
    const dir = mkdtempSync(join(tmpdir(), "pub-"));
    const dbPath = join(dir, "catalog.sqlite");
    writeFileSync(dbPath, Buffer.from("FAKE-SQLITE-BYTES"));
    const storage = new MemStorage();

    const manifest = await publishCatalog(dbPath, 3, storage, new Date("2026-07-04T09:00:00Z"));

    const artifact = storage.files.get("catalog/catalog-v3.sqlite.gz")!;
    expect(artifact.contentType).toBe("application/gzip");
    expect(gunzipSync(artifact.data).toString()).toBe("FAKE-SQLITE-BYTES");

    const expectedSha = createHash("sha256").update(artifact.data).digest("hex");
    expect(manifest).toEqual({
      version: 3, path: "catalog/catalog-v3.sqlite.gz", sha256: expectedSha,
      sizeBytes: artifact.data.length, generatedAt: "2026-07-04T09:00:00.000Z"
    });

    const manifestFile = storage.files.get("catalog/manifest.json")!;
    expect(JSON.parse(manifestFile.data.toString())).toEqual(manifest);
    expect(manifestFile.contentType).toBe("application/json");
  });
});
