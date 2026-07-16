import { describe, it, expect, vi } from "vitest";
import { issueSessionToken, verifySessionToken } from "../src/session";

describe("session tokens", () => {
  const secret = "test-secret";

  it("round-trips a valid token", () => {
    const token = issueSessionToken(secret, "device-1", 3600);
    const payload = verifySessionToken(secret, token);
    expect(payload?.keyId).toBe("device-1");
  });

  it("rejects a token signed with a different secret", () => {
    const token = issueSessionToken("other-secret", "device-1", 3600);
    expect(verifySessionToken(secret, token)).toBeNull();
  });

  it("rejects a tampered token", () => {
    const token = issueSessionToken(secret, "device-1", 3600);
    const tampered = token.slice(0, -1) + (token.at(-1) === "a" ? "b" : "a");
    expect(verifySessionToken(secret, tampered)).toBeNull();
  });

  it("rejects an expired token", () => {
    const realNow = Date.now;
    Date.now = () => new Date("2026-01-01T00:00:00Z").getTime();
    const token = issueSessionToken(secret, "device-1", 10);
    Date.now = () => new Date("2026-01-01T00:00:11Z").getTime();
    expect(verifySessionToken(secret, token)).toBeNull();
    Date.now = realNow;
  });
});
