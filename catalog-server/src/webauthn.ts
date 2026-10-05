import { decode as cborDecode } from "cbor";

export interface AuthenticatorData {
  rpIdHash: Buffer; flags: number; counter: number;
  aaguid?: Buffer; credentialId?: Buffer; credentialPublicKeyCose?: Buffer;
}

export interface ParseAuthDataOptions {
  /** True only for ATTESTATION authData, which is followed by attested credential data.
   *  The caller knows which message it holds; the AT flag does not say — see below. */
  attested?: boolean;
}

export function parseAuthenticatorData(buf: Buffer, opts: ParseAuthDataOptions = {}): AuthenticatorData {
  if (buf.length < 37) throw new Error("authData too short");
  const rpIdHash = buf.subarray(0, 32);
  const flags = buf[32];
  const counter = buf.readUInt32BE(33);
  const result: AuthenticatorData = { rpIdHash, flags, counter };
  // The LAYOUT is chosen by the caller, not by the AT (0x40) flag, because Apple sets AT in
  // assertion authData as well — where the buffer ends at 37 bytes, right after the counter.
  // Reading attested credential data whenever AT was set therefore walked past the end of every
  // real assertion ("offset out of range ... Received 53"), so verifyAssertion threw, /assert
  // answered 400 for every device, no counter ever advanced past 0, and clients silently
  // re-attested on each launch against Apple's per-key attestation rate limit.
  if (opts.attested) {
    if ((flags & 0x40) === 0) throw new Error("attestation authData has no attested credential data (AT flag clear)");
    // 16-byte AAGUID + 2-byte credential id length must both be present before either is read.
    if (buf.length < 55) throw new Error("attested credential data truncated");
    let offset = 37;
    result.aaguid = buf.subarray(offset, offset + 16); offset += 16;
    const credIdLen = buf.readUInt16BE(offset); offset += 2;
    if (offset + credIdLen > buf.length) throw new Error("credentialId length exceeds authData");
    result.credentialId = buf.subarray(offset, offset + credIdLen); offset += credIdLen;
    result.credentialPublicKeyCose = buf.subarray(offset);
  }
  return result;
}

function mapGet<T>(m: unknown, key: string): T {
  const value = m instanceof Map ? m.get(key) : (m as Record<string, unknown>)[key];
  if (value === undefined) throw new Error(`missing field: ${key}`);
  return value as T;
}

export interface AttestationObject { fmt: string; x5c: Buffer[]; receipt: Buffer; authData: Buffer; }

export function decodeAttestationObject(cborBytes: Buffer): AttestationObject {
  const decoded = cborDecode(cborBytes);
  const fmt = mapGet<string>(decoded, "fmt");
  const attStmt = mapGet<unknown>(decoded, "attStmt");
  const authData = mapGet<Buffer>(decoded, "authData");
  return { fmt, x5c: mapGet<Buffer[]>(attStmt, "x5c"), receipt: mapGet<Buffer>(attStmt, "receipt"), authData };
}

export interface AssertionObject { signature: Buffer; authenticatorData: Buffer; }

export function decodeAssertionObject(cborBytes: Buffer): AssertionObject {
  const decoded = cborDecode(cborBytes);
  return { signature: mapGet<Buffer>(decoded, "signature"), authenticatorData: mapGet<Buffer>(decoded, "authenticatorData") };
}
