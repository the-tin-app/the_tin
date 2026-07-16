import { describe, it, expect } from "vitest";
import { encode as cborEncode } from "cbor";
import { parseAuthenticatorData, decodeAttestationObject, decodeAssertionObject } from "../src/webauthn";

function buildAuthData(opts: { rpIdHash: Buffer; counter: number; attestedCredentialData?: { aaguid: Buffer; credentialId: Buffer; cosePublicKey: Buffer } }): Buffer {
  const flags = opts.attestedCredentialData ? 0x40 : 0x00;
  const counterBuf = Buffer.alloc(4);
  counterBuf.writeUInt32BE(opts.counter);
  const parts = [opts.rpIdHash, Buffer.from([flags]), counterBuf];
  if (opts.attestedCredentialData) {
    const credIdLen = Buffer.alloc(2);
    credIdLen.writeUInt16BE(opts.attestedCredentialData.credentialId.length);
    parts.push(opts.attestedCredentialData.aaguid, credIdLen, opts.attestedCredentialData.credentialId, opts.attestedCredentialData.cosePublicKey);
  }
  return Buffer.concat(parts);
}

describe("parseAuthenticatorData", () => {
  it("parses a buffer with no attested credential data", () => {
    const rpIdHash = Buffer.alloc(32, 7);
    const authData = buildAuthData({ rpIdHash, counter: 5 });
    const parsed = parseAuthenticatorData(authData);
    expect(parsed.rpIdHash).toEqual(rpIdHash);
    expect(parsed.flags).toBe(0);
    expect(parsed.counter).toBe(5);
    expect(parsed.credentialId).toBeUndefined();
  });

  it("parses attested credential data when the flag is set", () => {
    const rpIdHash = Buffer.alloc(32, 1);
    const aaguid = Buffer.alloc(16, 2);
    const credentialId = Buffer.from("cred-id");
    const cosePublicKey = Buffer.from("cose-key-bytes");
    const authData = buildAuthData({ rpIdHash, counter: 0, attestedCredentialData: { aaguid, credentialId, cosePublicKey } });
    const parsed = parseAuthenticatorData(authData);
    expect(parsed.flags & 0x40).toBe(0x40);
    expect(parsed.aaguid).toEqual(aaguid);
    expect(parsed.credentialId).toEqual(credentialId);
    expect(parsed.credentialPublicKeyCose).toEqual(cosePublicKey);
  });

  it("throws on a too-short buffer", () => {
    expect(() => parseAuthenticatorData(Buffer.alloc(10))).toThrow();
  });
});

describe("decodeAttestationObject", () => {
  it("decodes fmt, x5c, receipt, and authData from a CBOR map", () => {
    const authData = buildAuthData({ rpIdHash: Buffer.alloc(32), counter: 0 });
    const cbor = cborEncode(new Map<string, unknown>([
      ["fmt", "apple-appattest"],
      ["attStmt", new Map<string, unknown>([
        ["x5c", [Buffer.from("leaf-cert"), Buffer.from("intermediate-cert")]],
        ["receipt", Buffer.from("receipt-bytes")],
      ])],
      ["authData", authData],
    ]));
    const decoded = decodeAttestationObject(cbor);
    expect(decoded.fmt).toBe("apple-appattest");
    expect(decoded.x5c).toEqual([Buffer.from("leaf-cert"), Buffer.from("intermediate-cert")]);
    expect(decoded.receipt).toEqual(Buffer.from("receipt-bytes"));
    expect(decoded.authData).toEqual(authData);
  });

  it("throws when fmt is missing", () => {
    const cbor = cborEncode(new Map<string, unknown>([["attStmt", new Map()], ["authData", Buffer.alloc(37)]]));
    expect(() => decodeAttestationObject(cbor)).toThrow();
  });
});

describe("decodeAssertionObject", () => {
  it("decodes signature and authenticatorData from a CBOR map", () => {
    const authData = buildAuthData({ rpIdHash: Buffer.alloc(32), counter: 3 });
    const cbor = cborEncode(new Map<string, unknown>([
      ["signature", Buffer.from("sig-bytes")],
      ["authenticatorData", authData],
    ]));
    const decoded = decodeAssertionObject(cbor);
    expect(decoded.signature).toEqual(Buffer.from("sig-bytes"));
    expect(decoded.authenticatorData).toEqual(authData);
  });
});
