import { describe, it, expect, beforeEach, afterEach } from "vitest";
import Database from "better-sqlite3";
import { mkdtempSync, rmSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { splitTiers, publishTiers } from "../scripts/publish-tiers";
import { StoragePort } from "../src/pipeline/publish";
import { gzipSync } from "node:zlib";
import { createHash } from "node:crypto";

function tableExists(db: Database.Database, name: string): boolean {
  return !!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(name);
}
function rowCount(db: Database.Database, name: string): number {
  return (db.prepare(`SELECT COUNT(*) AS n FROM "${name}"`).get() as { n: number }).n;
}

describe("splitTiers", () => {
  let dir: string;
  let sourcePath: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "publish-tiers-"));
    sourcePath = join(dir, "source.sqlite");
    const db = new Database(sourcePath);
    db.exec(`
      CREATE TABLE card(id TEXT PRIMARY KEY, name TEXT);
      CREATE TABLE price_latest(card_id TEXT, raw_usd REAL);
      CREATE TABLE price_history(card_id TEXT, date TEXT, raw_usd REAL);
      CREATE TABLE price_history_cond(card_id TEXT, condition TEXT, date TEXT, usd REAL);
      CREATE TABLE graded_history(card_id TEXT, grade TEXT, date TEXT, usd REAL);
      INSERT INTO card VALUES ('c1', 'Pikachu');
      INSERT INTO price_latest VALUES ('c1', 2.0);
      INSERT INTO price_history VALUES ('c1', '2026-07-01', 1.5);
      INSERT INTO price_history_cond VALUES ('c1', 'NM', '2026-07-01', 1.4);
      INSERT INTO graded_history VALUES ('c1', 'PSA10', '2026-07-01', 90.0);
    `);
    db.close();
  });

  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("casual: keeps card+latest, price_history present but EMPTY, drops cond+graded", () => {
    const { casualPath } = splitTiers(sourcePath, join(dir, "out"));
    const db = new Database(casualPath);
    expect(rowCount(db, "card")).toBe(1);
    expect(rowCount(db, "price_latest")).toBe(1);
    expect(tableExists(db, "price_history")).toBe(true);
    expect(rowCount(db, "price_history")).toBe(0);           // emptied, not dropped
    expect(tableExists(db, "price_history_cond")).toBe(false);
    expect(tableExists(db, "graded_history")).toBe(false);
    db.close();
  });

  it("average: keeps populated price_history, drops cond+graded", () => {
    const { averagePath } = splitTiers(sourcePath, join(dir, "out"));
    const db = new Database(averagePath);
    expect(rowCount(db, "price_history")).toBe(1);
    expect(tableExists(db, "price_history_cond")).toBe(false);
    expect(tableExists(db, "graded_history")).toBe(false);
    db.close();
  });

  it("expert: keeps everything", () => {
    const { expertPath } = splitTiers(sourcePath, join(dir, "out"));
    const db = new Database(expertPath);
    expect(rowCount(db, "price_history")).toBe(1);
    expect(rowCount(db, "price_history_cond")).toBe(1);
    expect(rowCount(db, "graded_history")).toBe(1);
    db.close();
  });
});

class MemStore implements StoragePort {
  files = new Map<string, Buffer>();
  async save(path: string, data: Buffer) { this.files.set(path, Buffer.from(data)); }
}
const sha = (b: Buffer) => createHash("sha256").update(b).digest("hex");

describe("publishTiers", () => {
  let dir: string, sourcePath: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "publish-tiers-pub-"));
    sourcePath = join(dir, "source.sqlite");
    const db = new Database(sourcePath);
    db.exec(`
      CREATE TABLE card(id TEXT PRIMARY KEY, name TEXT);
      CREATE TABLE price_history(card_id TEXT, date TEXT, raw_usd REAL);
      CREATE TABLE price_history_cond(card_id TEXT, condition TEXT, date TEXT, usd REAL);
      CREATE TABLE graded_history(card_id TEXT, grade TEXT, date TEXT, usd REAL);
      INSERT INTO card VALUES ('c1','Pikachu');
      INSERT INTO price_history VALUES ('c1','2026-07-01',1.5);
    `);
    db.close();
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("writes three NAS artifacts + a manifest listing all three tiers", async () => {
    const fb = new MemStore();
    const nasDir = join(dir, "nas");
    const m = await publishTiers({ sourceDbPath: sourcePath, version: 8, nasDir,
      firebaseStorage: fb, now: new Date("2026-07-12T00:00:00Z"), publishToFirebase: true });

    expect(m.version).toBe(8);
    for (const tier of ["casual", "average", "expert"] as const) {
      const entry = m.tiers[tier];
      expect(entry.path).toBe(`${tier}-v8.sqlite.gz`);
      const bytes = readFileSync(join(nasDir, "catalog", entry.path));
      expect(sha(bytes)).toBe(entry.sha256);
      expect(bytes.length).toBe(entry.sizeBytes);
    }
    expect(existsSync(join(nasDir, "catalog", "manifest.json"))).toBe(true);
    expect(existsSync(join(nasDir, "_work"))).toBe(false);
  });

  it("casual bytes on NAS are sha256-identical to the Firebase upload", async () => {
    const fb = new MemStore();
    const nasDir = join(dir, "nas");
    const m = await publishTiers({ sourceDbPath: sourcePath, version: 8, nasDir,
      firebaseStorage: fb, now: new Date("2026-07-12T00:00:00Z"), publishToFirebase: true });

    const nasCasual = readFileSync(join(nasDir, "catalog", "casual-v8.sqlite.gz"));
    const fbCasual = fb.files.get("catalog/catalog-v8.sqlite.gz")!;
    expect(sha(fbCasual)).toBe(sha(nasCasual));
    expect(sha(nasCasual)).toBe(m.tiers.casual.sha256);
  });

  it("skips Firebase when publishToFirebase is false", async () => {
    const fb = new MemStore();
    await publishTiers({ sourceDbPath: sourcePath, version: 8, nasDir: join(dir, "nas"),
      firebaseStorage: fb, now: new Date("2026-07-12T00:00:00Z"), publishToFirebase: false });
    expect(fb.files.size).toBe(0);
  });
});
