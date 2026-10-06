import { describe, it, expect } from "vitest";
import { encode as cborEncode } from "cbor";
import { parseAuthenticatorData, decodeAttestationObject, decodeAssertionObject } from "../src/webauthn";

function buildAuthData(opts: { rpIdHash: Buffer; counter: number; flags?: number; attestedCredentialData?: { aaguid: Buffer; credentialId: Buffer; cosePublicKey: Buffer } }): Buffer {
  // `flags` is settable INDEPENDENTLY of attestedCredentialData on purpose: Apple's assertions set
  // AT (0x40) with no attested credential data following, and a helper that could not express that
  // combination is why the /assert parse bug shipped with these tests passing.
  const flags = opts.flags ?? (opts.attestedCredentialData ? 0x40 : 0x00);
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
    const parsed = parseAuthenticatorData(authData, { attested: true });
    expect(parsed.flags & 0x40).toBe(0x40);
    expect(parsed.aaguid).toEqual(aaguid);
    expect(parsed.credentialId).toEqual(credentialId);
    expect(parsed.credentialPublicKeyCose).toEqual(cosePublicKey);
  });

  it("throws on a too-short buffer", () => {
    expect(() => parseAuthenticatorData(Buffer.alloc(10))).toThrow();
  });

  // The shape Apple actually sends to POST /assert: exactly 37 bytes, AT flag SET, nothing after
  // the counter. Trusting the flag here read attested credential data off the end of the buffer
  // and failed every assertion in production.
  it("parses a real Apple assertion — 37 bytes with the AT flag set — without reading past the end", () => {
    const rpIdHash = Buffer.alloc(32, 9);
    const authData = buildAuthData({ rpIdHash, counter: 41, flags: 0x40 });
    expect(authData.length).toBe(37);
    const parsed = parseAuthenticatorData(authData);
    expect(parsed.rpIdHash).toEqual(rpIdHash);
    expect(parsed.flags & 0x40).toBe(0x40);
    expect(parsed.counter).toBe(41);
    expect(parsed.aaguid).toBeUndefined();
    expect(parsed.credentialId).toBeUndefined();
    expect(parsed.credentialPublicKeyCose).toBeUndefined();
  });

  it("rejects that same 37-byte buffer when the caller expects attestation", () => {
    const authData = buildAuthData({ rpIdHash: Buffer.alloc(32), counter: 0, flags: 0x40 });
    expect(() => parseAuthenticatorData(authData, { attested: true })).toThrow(/truncated/);
  });

  it("rejects attestation authData whose AT flag is clear", () => {
    const authData = buildAuthData({ rpIdHash: Buffer.alloc(32), counter: 0 });
    expect(() => parseAuthenticatorData(authData, { attested: true })).toThrow(/AT flag clear/);
  });

  it("rejects a credential id length that runs past the buffer", () => {
    const credIdLen = Buffer.alloc(2);
    credIdLen.writeUInt16BE(9999);
    const authData = Buffer.concat([
      buildAuthData({ rpIdHash: Buffer.alloc(32), counter: 0, flags: 0x40 }),
      Buffer.alloc(16, 2),
      credIdLen,
    ]);
    expect(() => parseAuthenticatorData(authData, { attested: true })).toThrow(/exceeds authData/);
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
