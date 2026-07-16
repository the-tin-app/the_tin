import * as forge from "node-forge";

const APPLE_APPATTEST_NONCE_OID = "1.2.840.113635.100.8.2";

function makeKeyPair() {
  return forge.pki.rsa.generateKeyPair(2048); // test-only chain; production leaf is real Apple EC key
}

export function generateLeafKeyPair(): forge.pki.KeyPair {
  return makeKeyPair();
}

export function publicKeyDerOfKeyPair(keys: forge.pki.KeyPair): Buffer {
  return Buffer.from(forge.asn1.toDer(forge.pki.publicKeyToAsn1(keys.publicKey)).getBytes(), "binary");
}

export interface TestChain { rootPem: string; leafDer: Buffer; intermediateDer: Buffer; leafPublicKeyDer: Buffer; }

/** Builds a synthetic root -> intermediate -> leaf chain with the Apple nonce extension baked
 *  into the leaf, so verifyAttestation's chain-of-trust and nonce-extraction logic can be
 *  exercised without real Apple-issued certificates. */
export function buildTestChain(nonce: Buffer, leafKeys: forge.pki.KeyPair = makeKeyPair()): TestChain {
  const rootKeys = makeKeyPair();
  const root = forge.pki.createCertificate();
  root.publicKey = rootKeys.publicKey;
  root.serialNumber = "01";
  root.validity.notBefore = new Date(2020, 0, 1);
  root.validity.notAfter = new Date(2040, 0, 1);
  root.setSubject([{ name: "commonName", value: "Test App Attest Root" }]);
  root.setIssuer(root.subject.attributes);
  root.sign(rootKeys.privateKey, forge.md.sha256.create());

  const intKeys = makeKeyPair();
  const intermediate = forge.pki.createCertificate();
  intermediate.publicKey = intKeys.publicKey;
  intermediate.serialNumber = "02";
  intermediate.validity.notBefore = new Date(2020, 0, 1);
  intermediate.validity.notAfter = new Date(2040, 0, 1);
  intermediate.setSubject([{ name: "commonName", value: "Test App Attest Intermediate" }]);
  intermediate.setIssuer(root.subject.attributes);
  intermediate.sign(rootKeys.privateKey, forge.md.sha256.create());

  const leaf = forge.pki.createCertificate();
  leaf.publicKey = leafKeys.publicKey;
  leaf.serialNumber = "03";
  leaf.validity.notBefore = new Date(2020, 0, 1);
  leaf.validity.notAfter = new Date(2040, 0, 1);
  leaf.setSubject([{ name: "commonName", value: "Test App Attest Leaf" }]);
  leaf.setIssuer(intermediate.subject.attributes);
  // Apple's extension: SEQUENCE { [1] EXPLICIT OCTET STRING (nonce) }
  const nonceAsn1 = forge.asn1.create(forge.asn1.Class.UNIVERSAL, forge.asn1.Type.SEQUENCE, true, [
    forge.asn1.create(forge.asn1.Class.CONTEXT_SPECIFIC, 1, true, [
      forge.asn1.create(forge.asn1.Class.UNIVERSAL, forge.asn1.Type.OCTETSTRING, false, nonce.toString("binary")),
    ]),
  ]);
  leaf.setExtensions([{ id: APPLE_APPATTEST_NONCE_OID, critical: false, value: forge.asn1.toDer(nonceAsn1).getBytes() }]);
  leaf.sign(intKeys.privateKey, forge.md.sha256.create());

  const der = (cert: forge.pki.Certificate) => Buffer.from(forge.asn1.toDer(forge.pki.certificateToAsn1(cert)).getBytes(), "binary");
  const publicKeyDer = (keys: forge.pki.KeyPair) => Buffer.from(forge.asn1.toDer(forge.pki.publicKeyToAsn1(keys.publicKey)).getBytes(), "binary");

  return { rootPem: forge.pki.certificateToPem(root), leafDer: der(leaf), intermediateDer: der(intermediate), leafPublicKeyDer: publicKeyDer(leafKeys) };
}
