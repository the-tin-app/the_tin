import { decode as cborDecode } from "cbor";

export interface AuthenticatorData {
  rpIdHash: Buffer; flags: number; counter: number;
  aaguid?: Buffer; credentialId?: Buffer; credentialPublicKeyCose?: Buffer;
}

export function parseAuthenticatorData(buf: Buffer): AuthenticatorData {
  if (buf.length < 37) throw new Error("authData too short");
  const rpIdHash = buf.subarray(0, 32);
  const flags = buf[32];
  const counter = buf.readUInt32BE(33);
  const result: AuthenticatorData = { rpIdHash, flags, counter };
  if ((flags & 0x40) !== 0) {
    let offset = 37;
    result.aaguid = buf.subarray(offset, offset + 16); offset += 16;
    const credIdLen = buf.readUInt16BE(offset); offset += 2;
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
