// ponytail: placeholder for Task 2. Real Firebase App Check verification is not implemented
// here — this always denies. Task 2 replaces this file wholesale with the real verifier.
export async function verifyAppCheckToken(_token: string, _env: unknown): Promise<boolean> {
  console.error("verifyAppCheckToken: STUB (Task 2 not yet implemented) — refusing all requests");
  return false;
}
