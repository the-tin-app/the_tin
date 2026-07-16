import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createPublicKey } from "node:crypto";
import { verifyAttestation } from "../src/appAttest";

// A REAL Apple App Attest attestation captured from a physical iPhone (development environment)
// via catalog-server's CAPTURE_ATTEST_PATH hook. This is the round-trip the deploy runbook's
// step 7 gate requires — the synthetic fixtures in fixtures.ts use RSA keys, but Apple's real
// leaf/intermediate certs are EC P-256, which node-forge cannot parse.
const fixture = JSON.parse(readFileSync(join(__dirname, "fixtures/real-attestation.json"), "utf8"));
const trustedRootPem = readFileSync(join(__dirname, "fixtures/apple-root-ca.pem"), "utf8");
const APP_ID = "GXP2X83CRN.ai.reyes.thetin";

function opts(overrides: Partial<Parameters<typeof verifyAttestation>[0]> = {}) {
  return {
    attestationObject: Buffer.from(fixture.attestationObject, "base64url"),
    keyId: Buffer.from(fixture.keyId, "base64url"),
    nonce: Buffer.from(fixture.nonce, "base64url"),
    appId: APP_ID,
    trustedRootPem,
    environment: "development" as const,
    ...overrides,
  };
}

describe("verifyAttestation against a real Apple attestation", () => {
  it("accepts a genuine development attestation and returns a re-importable EC public key", () => {
    // Not throwing proves the internal keyId check (sha256 of the raw EC point == keyId) passed.
    const { publicKeyDer } = verifyAttestation(opts());
    expect(publicKeyDer.length).toBeGreaterThan(0);
    const key = createPublicKey({ key: publicKeyDer, format: "der", type: "spki" });
    expect(key.asymmetricKeyType).toBe("ec");
  });

  it("rejects a corrupted attestation (one byte flipped inside the cert chain)", () => {
    const tampered = Buffer.from(fixture.attestationObject, "base64url");
    tampered[100] ^= 0x01;
    expect(() => verifyAttestation(opts({ attestationObject: tampered }))).toThrow();
  });

  it("rejects a mismatched nonce", () => {
    const wrongNonce = Buffer.from(fixture.nonce, "base64url");
    wrongNonce[0] ^= 0x01;
    expect(() => verifyAttestation(opts({ nonce: wrongNonce }))).toThrow(/nonce/i);
  });

  it("rejects a mismatched appId (rpIdHash)", () => {
    expect(() => verifyAttestation(opts({ appId: "GXP2X83CRN.ai.reyes.wrong" }))).toThrow(/rpIdHash/);
  });

  it("rejects when the server expects the production environment", () => {
    expect(() => verifyAttestation(opts({ environment: "production" }))).toThrow(/AAGUID/);
  });
});
