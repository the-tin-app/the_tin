import Database from "better-sqlite3";

export interface Device { keyId: string; publicKeyDer: Buffer; counter: number; firstSeen: string; }

export interface DeviceStore {
  upsertDevice(d: Device): void;
  getDevice(keyId: string): Device | undefined;
  bumpCounter(keyId: string, counter: number): void;
}

export function openDeviceStore(dbPath: string): DeviceStore {
  const db = new Database(dbPath);
  db.exec(`
    CREATE TABLE IF NOT EXISTS devices(
      key_id TEXT PRIMARY KEY,
      public_key_der BLOB NOT NULL,
      counter INTEGER NOT NULL,
      first_seen TEXT NOT NULL
    )
  `);
  const upsertStmt = db.prepare(`
    INSERT INTO devices(key_id, public_key_der, counter, first_seen) VALUES (@keyId, @publicKeyDer, @counter, @firstSeen)
    ON CONFLICT(key_id) DO UPDATE SET public_key_der = @publicKeyDer, counter = @counter
  `);
  const getStmt = db.prepare("SELECT key_id, public_key_der, counter, first_seen FROM devices WHERE key_id = ?");
  const bumpStmt = db.prepare("UPDATE devices SET counter = ? WHERE key_id = ?");

  return {
    upsertDevice(d) {
      upsertStmt.run({ keyId: d.keyId, publicKeyDer: d.publicKeyDer, counter: d.counter, firstSeen: d.firstSeen });
    },
    getDevice(keyId) {
      const row = getStmt.get(keyId) as { key_id: string; public_key_der: Buffer; counter: number; first_seen: string } | undefined;
      if (!row) return undefined;
      return { keyId: row.key_id, publicKeyDer: row.public_key_der, counter: row.counter, firstSeen: row.first_seen };
    },
    bumpCounter(keyId, counter) {
      const result = bumpStmt.run(counter, keyId);
      if (result.changes === 0) throw new Error(`bumpCounter: unknown device ${keyId}`);
    },
  };
}
