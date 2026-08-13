# Sync, sharing and backup — 1.0.4 design

**Status:** design, 2026-08-13. No code. Targets **1.0.4, alongside the Android build**.

The first version of this doc presented a trilemma — cross-platform reach, hosting
nothing, automatic sync, pick two. **Android at 1.0.4 settles it:** cross-platform is a
requirement, so hosting nothing is off the table and CloudKit is out permanently. What
follows is the design for the remaining option, and the decisions taken on 2026-08-13.

## The guarantee

> Someone with full access to the storage bucket — including the operator — cannot read
> anyone's collection.

Everything below follows from taking that literally. The consequence, stated once here
because it cannot be engineered away: **a user who loses their recovery code and all
their devices has lost their data permanently, and we cannot help them.** That must be
said in the opt-in flow and in the privacy policy, not buried.

## Why this also answers the cost question

Because the payload is end-to-end encrypted, the server can only ever hold **opaque
blobs**. Ciphertext cannot be queried, indexed or filtered. So any per-document database
bills database prices for functionality the encryption has already made unusable.

That eliminates Firestore on cost *and* on fit: a 3,000-card tin is 3,000 document reads
per full sync, against one object read for a blob. It is also the concrete answer to
"I am against firebase if the cost is too crazy" — the objection was right, for a more
fundamental reason than price.

| | R2 (chosen) | Firestore | S3 |
|---|---|---|---|
| Egress | **$0** | charged | charged |
| Pricing unit | bytes + ops | **per document** | bytes + ops + egress |
| Cost scales with | data size, write rate | **record count** | size + reads + egress |
| Already in the stack | ✅ `tin-artifacts` | partly (App Check) | ✗ |

## Architecture

Reuses what exists: the `tin-backup` Worker on `backupthetin.reyes.ai`, the `tin-artifacts`
R2 bucket, and Firebase **App Check** attestation, which the Worker already verifies
against Google's JWKS. The new build is the crypto and the merge format — not the
platform.

- **Per-device append-only segments.** Each device writes its own encrypted segments; no
  device ever overwrites another's. This is what ends the last-writer-wins data loss,
  and it needs no server-side coordination — which is just as well, because the server
  cannot read enough to coordinate anything.
- **Merge is client-side**, after decryption: per-entry ids with `modifiedAt`, tombstones
  for deletes, reconcile on pull. Periodic compaction rewrites a snapshot and drops
  superseded segments.
- **The wire format is platform-neutral** and explicitly *not* the SQLite schema, or
  Android cannot read it.

The three known failures from the backup era are all merge failures and are all fixed
here rather than carried forward: deletions need two paths; the seed-only fold must fold
*everything*, not just post-opt-in records; the no-op-write skip needs deterministic
encoding (`.sortedKeys`) to fire at all.

## Decisions taken 2026-08-13

### Keys — device key + one-time recovery code

A random 256-bit key in the iOS Keychain / Android Keystore, propagated within an
ecosystem by iCloud Keychain and Google Block Store, plus a **printable one-time recovery
code**. The code is not only for disaster: it is the mechanism for crossing ecosystems,
which 1.0.4 needs anyway the moment someone moves iPhone → Android.

Rejected: a server-wrapped key, which has the best UX and breaks the guarantee outright —
whoever holds the wrapping key can decrypt. Rejected: passphrase-only, which needs no
platform support but makes forgotten passphrases the most common support request.

Use vetted primitives — CryptoKit on iOS, Tink or libsodium on Android. AEAD with a
per-object nonce, HKDF for subkey derivation. Encrypt names and metadata too; object keys
leak structure otherwise.

### Identity — none

No accounts. The storage id is derived from the key, so the server issues no identity and
stores blobs under a meaningless label. Zero PII by construction. The cost: a deletion
request cannot be authenticated by login, so the client proves possession by signing a
challenge.

### Photos — separate opt-in, hard quota

Photos are ~2 MB against a ~500 KB tin — roughly **100× the payload**, accumulating
forever, and the most sensitive content we would hold. They get their own toggle *inside*
the sync opt-in, and a hard per-user cap. Egress being free keeps this affordable; the
quota is what bounds the worst case.

### Residency — EU-jurisdiction bucket from day one

R2 supports jurisdiction-pinned buckets. Chosen now rather than later because migrating
objects after launch is real work and this is the cleanest answer when an EU user asks
where their data lives. Slightly higher latency for non-EU users, accepted.

### Write frequency — debounced

Sync-on-every-change is what makes these systems expensive. Coalesce and flush on a timer
and on background, not per keystroke. This is the single biggest lever on the bill, and it
costs no user-facing promise — per `DESIGN.md §6`, nothing may promise speed anyway.

## Cost model

**Verify against current published pricing before committing.** The shape is the reliable
part: R2 bills bytes and operations with zero egress, so **the bill tracks write frequency,
not user count.**

Assumptions: ~500 KB ciphertext per tin, photos excluded, debounced writes.

| Users | Storage | Est. monthly |
|---|---|---|
| 10k | ~5 GB (inside free tier) | **~$2–5** |
| 100k | ~50 GB | **~$25–70** |

The 100k spread is almost entirely write frequency. Photos, at the quota, are additive
storage — cheap per GB, but monotonically growing, which is the reason for the cap.

### The real cost risk is abuse, not growth

Without accounts, nothing inherently stops scripted uploads running up the bill. App Check
is already enforced in the Worker; it needs per-id storage quota, an object-size cap, and
rate limiting. **This is the difference between a predictable bill and an unbounded one**,
and it should ship with the first byte of sync, not after.

## Legal

Encryption at rest does **not** remove GDPR obligations: pseudonymous ciphertext is still
personal data. What changes:

- **Lawful basis** becomes consent, which the opt-in design supports directly.
- **A Cloudflare DPA** is required, as they become a processor.
- **Deletion** must be a real path: an in-app "delete my cloud data", plus a documented
  route for a request arriving by email against an opaque id.
- **Residency** is answered by the EU bucket above.

### The privacy policy is not updated yet, deliberately

`site/privacy/index.html` needs material edits to **What we collect**, **What we don't
collect** (which currently claims more than will remain true), **Third-party services**,
**Data deletion**, and **Children**. That last one matters more than usual: a Pokémon app
skews young, and this is the first feature where we host user-generated content.

Those edits should land **with the feature, not before it**. Publishing a policy that
describes collection which is not yet happening is its own inaccuracy.

## Still open

1. The recovery-code format and exactly where it is shown — once at opt-in is decided;
   whether it can be re-displayed later is not.
2. Quota numbers: per-user storage cap, object-size cap, rate limit.
3. Whether sharing rides this transport at 1.0.4 or stays on the existing share-link
   surface. Sharing needs a fresh per-share key in the URL **fragment** (never sent to the
   server) and lifecycle-rule expiry, but it does not otherwise depend on sync landing.
4. Whether a second reviewer — legal, not engineering — is warranted before launch given
   the residency and children questions.
