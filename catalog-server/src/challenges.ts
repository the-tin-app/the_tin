import { randomBytes } from "node:crypto";

export interface ChallengeStore {
  issue(): string;
  consume(nonce: string): boolean;
}

export function createChallengeStore(ttlSeconds: number): ChallengeStore {
  const pending = new Map<string, number>(); // nonce -> expiry epoch seconds

  return {
    issue() {
      const now = Math.floor(Date.now() / 1000);
      // ponytail: opportunistic sweep bounds Map growth from unconsumed/expired
      // nonces on this unauthenticated endpoint, without a timer. Upgrade to a
      // scheduled sweep if issue() call volume ever stops being frequent enough
      // to keep the store bounded on its own.
      for (const [existingNonce, expiry] of pending) {
        if (expiry < now) pending.delete(existingNonce);
      }
      const nonce = randomBytes(16).toString("base64url");
      pending.set(nonce, now + ttlSeconds);
      return nonce;
    },
    consume(nonce) {
      const expiry = pending.get(nonce);
      pending.delete(nonce);
      if (expiry === undefined) return false;
      return expiry >= Math.floor(Date.now() / 1000);
    },
  };
}
