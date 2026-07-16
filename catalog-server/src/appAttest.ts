import * as forge from "node-forge";
import { X509Certificate, KeyObject, createHash, createPublicKey, verify as cryptoVerify } from "node:crypto";
import { parseAuthenticatorData, decodeAttestationObject, decodeAssertionObject } from "./webauthn";

const APPLE_APPATTEST_NONCE_OID = "1.2.840.113635.100.8.2";
export const AAGUID_DEVELOPMENT = Buffer.from("appattestdevelop", "ascii");
export const AAGUID_PRODUCTION = Buffer.concat([Buffer.from("appattest", "ascii"), Buffer.alloc(7)]);

// Apple App Attest certs are EC P-256 (root P-384); node-forge cannot parse EC public keys
// (`Cannot read public key. OID is not RSA.`), so cert parsing, chain verification, and public-key
// export all go through node's built-in X509Certificate. forge is retained ONLY as a low-level
// ASN.1 reader for the custom nonce extension, which X509Certificate doesn't expose — and
// forge.asn1.fromDer (unlike pki.certificateFromAsn1) never touches the EC public key, so it's safe.

/// Pull Apple's nonce extension (OID 1.2.840.113635.100.8.2) straight from the leaf's DER.
/// Structure: extnValue OCTET STRING → SEQUENCE { [1] EXPLICIT { OCTET STRING nonce } }.
function extractNonceExtension(certDer: Buffer): Buffer {
  const cert = forge.asn1.fromDer(forge.util.createBuffer(certDer.toString("binary")));
  const tbs = cert.value[0] as forge.asn1.Asn1; // TBSCertificate
  const extsWrapper = (tbs.value as forge.asn1.Asn1[]).find(
    (el) => el.tagClass === forge.asn1.Class.CONTEXT_SPECIFIC && el.type === 3,
  );
  if (!extsWrapper) throw new Error("leaf certificate has no extensions");
  const extensions = (extsWrapper.value[0] as forge.asn1.Asn1).value as forge.asn1.Asn1[];
  for (const ext of extensions) {
    const parts = ext.value as forge.asn1.Asn1[]; // Extension ::= { OID, [critical BOOLEAN], OCTET STRING }
    if (forge.asn1.derToOid(parts[0].value as string) !== APPLE_APPATTEST_NONCE_OID) continue;
    const extnValue = parts[parts.length - 1]; // extnValue OCTET STRING (after optional critical flag)
    const inner = forge.asn1.fromDer(extnValue.value as string);
    const wrapper = inner.value[0] as forge.asn1.Asn1; // [1] EXPLICIT
    const octetString = wrapper.value[0] as forge.asn1.Asn1;
    return Buffer.from(octetString.value as string, "binary");
  }
  throw new Error("leaf certificate missing App Attest nonce extension");
}

/// Apple's keyId is SHA-256 of the RAW uncompressed EC point (0x04 || X || Y) — NOT the SPKI DER.
function rawEcPoint(key: KeyObject): Buffer {
  const jwk = key.export({ format: "jwk" }) as { x?: string; y?: string };
  if (!jwk.x || !jwk.y) throw new Error("leaf public key is not an EC key");
  return Buffer.concat([Buffer.from([0x04]), Buffer.from(jwk.x, "base64url"), Buffer.from(jwk.y, "base64url")]);
}

export interface AttestOptions { attestationObject: Buffer; keyId: Buffer; nonce: Buffer; appId: string; trustedRootPem: string; environment: "development" | "production"; }
export interface AttestedDevice { publicKeyDer: Buffer; }

// Validated against a real Apple-issued attestation captured from a physical iPhone
// (test/fixtures/real-attestation.json + test/appAttestReal.test.ts) — the runbook step-7 gate.
export function verifyAttestation(opts: AttestOptions): AttestedDevice {
  const { fmt, x5c, authData } = decodeAttestationObject(opts.attestationObject);
  if (fmt !== "apple-appattest") throw new Error(`unexpected fmt: ${fmt}`);
  if (!x5c || x5c.length < 2) throw new Error("missing certificate chain");

  const leaf = new X509Certificate(x5c[0]);
  const intermediate = new X509Certificate(x5c[1]);
  const root = new X509Certificate(opts.trustedRootPem);

  // Signature chain: leaf ← intermediate ← trusted Apple root. `verify(key)` checks that the cert
  // was signed by the private key matching `key` (i.e. its issuer's public key).
  if (!intermediate.verify(root.publicKey)) throw new Error("intermediate not signed by trusted root");
  if (!leaf.verify(intermediate.publicKey)) throw new Error("leaf not signed by intermediate");

  const clientDataHash = createHash("sha256").update(opts.nonce).digest();
  const composedNonce = createHash("sha256").update(Buffer.concat([authData, clientDataHash])).digest();
  const certNonce = extractNonceExtension(x5c[0]);
  if (!certNonce.equals(composedNonce)) throw new Error("nonce mismatch");

  const parsed = parseAuthenticatorData(authData);
  const expectedRpIdHash = createHash("sha256").update(opts.appId).digest();
  if (!parsed.rpIdHash.equals(expectedRpIdHash)) throw new Error("rpIdHash mismatch");
  if (parsed.counter !== 0) throw new Error("attestation counter must be 0 for a fresh key");
  if (!parsed.credentialId || !parsed.credentialId.equals(opts.keyId)) throw new Error("credentialId does not match keyId");

  const expectedAaguid = opts.environment === "development" ? AAGUID_DEVELOPMENT : AAGUID_PRODUCTION;
  if (!parsed.aaguid || !parsed.aaguid.equals(expectedAaguid)) {
    throw new Error(`AAGUID does not match expected "${opts.environment}" environment`);
  }

  const derivedKeyId = createHash("sha256").update(rawEcPoint(leaf.publicKey)).digest();
  if (!derivedKeyId.equals(opts.keyId)) {
    throw new Error("keyId does not match SHA-256 of the leaf certificate's public key");
  }

  // Store SPKI DER — that's what verifyAssertion re-imports via createPublicKey({type:'spki'}).
  return { publicKeyDer: leaf.publicKey.export({ type: "spki", format: "der" }) as Buffer };
}

export interface AssertOptions { assertionObject: Buffer; nonce: Buffer; appId: string; storedPublicKeyDer: Buffer; storedCounter: number; }
export interface AssertedSession { newCounter: number; }

export function verifyAssertion(opts: AssertOptions): AssertedSession {
  const { signature, authenticatorData } = decodeAssertionObject(opts.assertionObject);
  const parsed = parseAuthenticatorData(authenticatorData);
  const expectedRpIdHash = createHash("sha256").update(opts.appId).digest();
  if (!parsed.rpIdHash.equals(expectedRpIdHash)) throw new Error("rpIdHash mismatch");
  if (parsed.counter <= opts.storedCounter) throw new Error("counter did not strictly increase (possible replay)");

  const clientDataHash = createHash("sha256").update(opts.nonce).digest();
  const signedData = createHash("sha256").update(Buffer.concat([authenticatorData, clientDataHash])).digest();
  const publicKey = createPublicKey({ key: opts.storedPublicKeyDer, format: "der", type: "spki" });
  // "sha256" (not null) is required here: unlike Ed25519/Ed448, ECDSA (P-256) has no built-in
  // digest, so Node needs the algorithm named explicitly even though signedData is itself
  // already a SHA-256 digest of authenticatorData || clientDataHash (Apple's documented "verify
  // sig is a valid signature over nonce" step).
  if (!cryptoVerify("sha256", signedData, publicKey, signature)) throw new Error("assertion signature invalid");

  return { newCounter: parsed.counter };
}
