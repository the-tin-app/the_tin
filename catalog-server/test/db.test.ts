import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDeviceStore, DeviceStore } from "../src/db";

describe("device store", () => {
  let dir: string;
  let store: DeviceStore;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "catalog-server-db-"));
    store = openDeviceStore(join(dir, "devices.sqlite"));
  });

  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("returns undefined for an unknown device", () => {
    expect(store.getDevice("nope")).toBeUndefined();
  });

  it("round-trips a device through upsert and get", () => {
    store.upsertDevice({ keyId: "abc", publicKeyDer: Buffer.from("pubkey"), counter: 0, firstSeen: "2026-07-12T00:00:00Z" });
    const d = store.getDevice("abc");
    expect(d).toEqual({ keyId: "abc", publicKeyDer: Buffer.from("pubkey"), counter: 0, firstSeen: "2026-07-12T00:00:00Z" });
  });

  it("bumpCounter updates the stored counter", () => {
    store.upsertDevice({ keyId: "abc", publicKeyDer: Buffer.from("pubkey"), counter: 0, firstSeen: "2026-07-12T00:00:00Z" });
    store.bumpCounter("abc", 5);
    expect(store.getDevice("abc")!.counter).toBe(5);
  });

  it("bumpCounter throws for an unknown device", () => {
    expect(() => store.bumpCounter("nope", 1)).toThrow();
  });
});
