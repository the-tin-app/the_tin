import { describe, it, expect } from "vitest";
import { encode as cborEncode } from "cbor";
import { createHash, generateKeyPairSync, sign as cryptoSign } from "node:crypto";
import { verifyAttestation, verifyAssertion, AAGUID_DEVELOPMENT, AAGUID_PRODUCTION } from "../src/appAttest";
import { buildTestChain, generateLeafKeyPair, publicKeyDerOfKeyPair } from "./fixtures";

const APP_ID = "TESTTEAM.ai.reyes.thetin";

function buildAuthData(rpIdHash: Buffer, counter: number, attested?: { aaguid: Buffer; credentialId: Buffer; cosePublicKey: Buffer }) {
  const flags = attested ? 0x40 : 0x00;
  const counterBuf = Buffer.alloc(4); counterBuf.writeUInt32BE(counter);
  const parts = [rpIdHash, Buffer.from([flags]), counterBuf];
  if (attested) {
    const lenBuf = Buffer.alloc(2); lenBuf.writeUInt16BE(attested.credentialId.length);
    parts.push(attested.aaguid, lenBuf, attested.credentialId, attested.cosePublicKey);
  }
  return Buffer.concat(parts);
}

describe("verifyAttestation", () => {
  // The happy path is covered authoritatively by appAttestReal.test.ts against a real Apple EC
  // attestation. These synthetic-chain cases exercise the individual rejection branches; the
  // fixtures are RSA stand-ins (node-forge can't mint EC certs), so they can only prove rejection,
  // never acceptance — Apple's real leaf is EC P-256.
  it("rejects an attestation whose nonce extension doesn't match", () => {
    const leafKeys = generateLeafKeyPair();
    const keyId = createHash("sha256").update(publicKeyDerOfKeyPair(leafKeys)).digest();
    const rpIdHash = createHash("sha256").update(APP_ID).digest();
    const authData = buildAuthData(rpIdHash, 0, { aaguid: AAGUID_PRODUCTION, credentialId: keyId, cosePublicKey: Buffer.from("cose") });
    const chain = buildTestChain(Buffer.from("wrong-nonce-entirely-000000000000"), leafKeys);
    const attestationObject = cborEncode(new Map<string, unknown>([
      ["fmt", "apple-appattest"],
      ["attStmt", new Map<string, unknown>([["x5c", [chain.leafDer, chain.intermediateDer]], ["receipt", Buffer.from("r")]])],
      ["authData", authData],
    ]));
    expect(() => verifyAttestation({ attestationObject, keyId, nonce: Buffer.from("server-challenge"), appId: APP_ID, trustedRootPem: chain.rootPem, environment: "production" }))
      .toThrow();
  });

  it("rejects a chain not signed by the trusted root", () => {
    const leafKeys = generateLeafKeyPair();
    const keyId = createHash("sha256").update(publicKeyDerOfKeyPair(leafKeys)).digest();
    const nonceInput = Buffer.from("server-challenge");
    const clientDataHash = createHash("sha256").update(nonceInput).digest();
    const rpIdHash = createHash("sha256").update(APP_ID).digest();
    const authData = buildAuthData(rpIdHash, 0, { aaguid: AAGUID_PRODUCTION, credentialId: keyId, cosePublicKey: Buffer.from("cose") });
    const composedNonce = createHash("sha256").update(Buffer.concat([authData, clientDataHash])).digest();
    const chain = buildTestChain(composedNonce, leafKeys);
    const otherChain = buildTestChain(composedNonce); // different root, unrelated leaf key
    const attestationObject = cborEncode(new Map<string, unknown>([
      ["fmt", "apple-appattest"],
      ["attStmt", new Map<string, unknown>([["x5c", [chain.leafDer, chain.intermediateDer]], ["receipt", Buffer.from("r")]])],
      ["authData", authData],
    ]));
    expect(() => verifyAttestation({ attestationObject, keyId, nonce: nonceInput, appId: APP_ID, trustedRootPem: otherChain.rootPem, environment: "production" }))
      .toThrow();
  });

  it("rejects an AAGUID that doesn't match the expected environment", () => {
    const leafKeys = generateLeafKeyPair();
    const keyId = createHash("sha256").update(publicKeyDerOfKeyPair(leafKeys)).digest();
    const nonceInput = Buffer.from("server-challenge");
    const clientDataHash = createHash("sha256").update(nonceInput).digest();
    const rpIdHash = createHash("sha256").update(APP_ID).digest();
    // Embeds the DEVELOPMENT AAGUID, but the server below checks against "production".
    const authData = buildAuthData(rpIdHash, 0, { aaguid: AAGUID_DEVELOPMENT, credentialId: keyId, cosePublicKey: Buffer.from("cose") });
    const composedNonce = createHash("sha256").update(Buffer.concat([authData, clientDataHash])).digest();
    const chain = buildTestChain(composedNonce, leafKeys);
    const attestationObject = cborEncode(new Map<string, unknown>([
      ["fmt", "apple-appattest"],
      ["attStmt", new Map<string, unknown>([["x5c", [chain.leafDer, chain.intermediateDer]], ["receipt", Buffer.from("r")]])],
      ["authData", authData],
    ]));
    expect(() => verifyAttestation({ attestationObject, keyId, nonce: nonceInput, appId: APP_ID, trustedRootPem: chain.rootPem, environment: "production" }))
      .toThrow();
  });

  it("rejects a keyId that doesn't match SHA-256 of the leaf certificate's public key", () => {
    const leafKeys = generateLeafKeyPair();
    const wrongKeyId = Buffer.from("not-the-real-hash-of-the-public-key");
    const nonceInput = Buffer.from("server-challenge");
    const clientDataHash = createHash("sha256").update(nonceInput).digest();
    const rpIdHash = createHash("sha256").update(APP_ID).digest();
    // credentialId matches keyId (so the pre-existing credentialId check passes), but neither is
    // a real hash of the leaf's public key, so the new cross-check must catch it.
    const authData = buildAuthData(rpIdHash, 0, { aaguid: AAGUID_PRODUCTION, credentialId: wrongKeyId, cosePublicKey: Buffer.from("cose") });
    const composedNonce = createHash("sha256").update(Buffer.concat([authData, clientDataHash])).digest();
    const chain = buildTestChain(composedNonce, leafKeys);
    const attestationObject = cborEncode(new Map<string, unknown>([
      ["fmt", "apple-appattest"],
      ["attStmt", new Map<string, unknown>([["x5c", [chain.leafDer, chain.intermediateDer]], ["receipt", Buffer.from("r")]])],
      ["authData", authData],
    ]));
    expect(() => verifyAttestation({ attestationObject, keyId: wrongKeyId, nonce: nonceInput, appId: APP_ID, trustedRootPem: chain.rootPem, environment: "production" }))
      .toThrow();
  });
});

describe("verifyAssertion", () => {
  // An assertion's signature is plain ECDSA-P256/SHA256 over SHA256(authenticatorData ||
  // clientDataHash) — no certificate chain involved, so this generates a real EC keypair
  // directly (not the RSA test-chain from fixtures.ts) and produces a genuinely valid signature.
  // This exercises the full verify path with real cryptography; only the attestation
  // certificate-chain fixtures are synthetic stand-ins for Apple's, per Task 6 Step 7.
  function buildAssertionFixture(opts: { counter: number; appId?: string; tamperSignature?: boolean }) {
    const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const publicKeyDer = publicKey.export({ format: "der", type: "spki" }) as Buffer;
    const nonce = Buffer.from("assert-challenge");
    const clientDataHash = createHash("sha256").update(nonce).digest();
    const rpIdHash = createHash("sha256").update(opts.appId ?? APP_ID).digest();
    const authenticatorData = buildAuthData(rpIdHash, opts.counter);
    const signedData = createHash("sha256").update(Buffer.concat([authenticatorData, clientDataHash])).digest();
    const signature = cryptoSign("sha256", signedData, privateKey);
    if (opts.tamperSignature) signature[0] ^= 0xff;
    const assertionObject = cborEncode(new Map<string, unknown>([["signature", signature], ["authenticatorData", authenticatorData]]));
    return { assertionObject, nonce, publicKeyDer };
  }

  it("accepts a valid assertion and returns the new counter", () => {
    const { assertionObject, nonce, publicKeyDer } = buildAssertionFixture({ counter: 4 });
    const result = verifyAssertion({ assertionObject, nonce, appId: APP_ID, storedPublicKeyDer: publicKeyDer, storedCounter: 3 });
    expect(result.newCounter).toBe(4);
  });

  it("rejects a counter that did not strictly increase", () => {
    const { assertionObject, nonce, publicKeyDer } = buildAssertionFixture({ counter: 3 });
    expect(() => verifyAssertion({ assertionObject, nonce, appId: APP_ID, storedPublicKeyDer: publicKeyDer, storedCounter: 3 })).toThrow();
  });

  it("rejects a tampered signature", () => {
    const { assertionObject, nonce, publicKeyDer } = buildAssertionFixture({ counter: 4, tamperSignature: true });
    expect(() => verifyAssertion({ assertionObject, nonce, appId: APP_ID, storedPublicKeyDer: publicKeyDer, storedCounter: 3 })).toThrow();
  });

  it("rejects a mismatched rpIdHash", () => {
    const { assertionObject, nonce, publicKeyDer } = buildAssertionFixture({ counter: 4, appId: "wrong.app.id" });
    expect(() => verifyAssertion({ assertionObject, nonce, appId: APP_ID, storedPublicKeyDer: publicKeyDer, storedCounter: 3 })).toThrow();
  });
});
