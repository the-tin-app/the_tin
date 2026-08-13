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

### Photos — user-owned storage, never ours

**We host no user-generated images.** Photos stay in the user's own cloud: the iCloud
container on iOS, as they already do today, and a Google Drive app folder on Android.
Only tins pass through R2.

This reverses an earlier decision (separate opt-in behind a quota) and the reason is not
cost — at the quota it was a few dollars a month. It is that **hosting user-generated
images from a user base that skews young is the one part of this design that would have
warranted legal review**, and there is no budget for one on a free app funded personally.
Removing the category is cheaper than advising on it, and it is the only item here where
"we couldn't afford advice" would not have been much of a defence.

Knock-on effects, all of them simplifications: no UGC in the privacy policy, none in the
App Store privacy labels, no image-storage quota to enforce, and no moderation question
to answer.

### …and a portable archive covers the gap

Not hosting photos would otherwise mean they never cross ecosystems. Instead the app
**exports them as a plain zip and the user decides where it goes** — another device, a
drive, their own cloud. Same category as the existing CSV export: we write a file, we
host nothing, and the legal position above is unchanged.

**The mapping already exists.** Photos are stored at
`Application Support/CardPhotos/<entryId>/<uuid>.jpg`, and `PhotoStore.needed(from:)`
already returns exactly `entryId → [filename]`. The archive is that directory plus a
manifest serialised from a function we already have — there is no new data model here.

    manifest.json   { version, exportedAt, entries: { <entryId>: [<file>, …] } }
    photos/<entryId>/<uuid>.jpg

**Import attaches by entry id, and does not guess.** Entry ids survive sync, so the clean
path is: sync the tin first, then import the archive on the second device and the ids line
up. Where an id has no match — a tin built independently, an entry deleted since export —
the photos are held aside and reported, **not** fuzzy-matched on card + condition + grade.
Several copies of one card are common, and a photo silently attached to the wrong copy is
worse than one that arrives unattached.

**No new dependency.** `NSFileCoordinator(readingItemAt:options:.forUploading)` zips a
directory on iOS; `java.util.zip` is standard on Android. GzipSwift is already in the
project and is *not* a zip library — don't reach for it here. Photos are downscaled on
save, so archives stay modest, but the write should stream rather than build in memory.

**This replaces the Google Drive app-folder integration**, which is no longer needed on
either side: the system share sheet and Android's storage-access framework already put the
file wherever the user wants, without an SDK.

⚠️ **The reopening condition, stated precisely.** "Store the zip in the cloud" is fine when
*the user's* cloud is meant. If it ever means *our* storage, we are hosting
user-generated images again and the legal-review question from the Legal section reopens
with it. The distinction is who chose the destination, not whether the bytes are
encrypted.

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

The 100k spread is almost entirely write frequency. Photos are absent from this table by
design, not omission — they never reach our storage at all, so the largest and
fastest-growing payload is simply not on the bill.

### The real cost risk is abuse, not growth

Without accounts, nothing inherently stops scripted uploads running up the bill. App Check
is already enforced in the Worker; it needs per-id storage quota, an object-size cap, and
rate limiting. **This is the difference between a predictable bill and an unbounded one**,
and it should ship with the first byte of sync, not after.

## Legal — scoped to stay self-serviceable

**Constraint, 2026-08-13: there is no budget for legal review.** This is a free app funded
out of pocket with zero donors, so the design is shaped to stay inside what a solo
developer can responsibly self-serve, rather than shaped first and reviewed after.

What that actually requires is separating the obligations that need advice from the ones
that don't:

| | Needs a lawyer? |
|---|---|
| Cloudflare DPA | No — click-through, not negotiated |
| EU-jurisdiction bucket | No — a config flag |
| Privacy policy for no-accounts, ciphertext-only | No — the less held, the more it is genuinely boilerplate |
| **Hosting user-generated images from a young user base** | **Yes — so it was removed** |

Dropping cloud photo hosting (above) is what takes this from "should be reviewed" to
"self-serviceable". What remains is ciphertext we cannot read, under ids that map to no
person, in a chosen region, with a deletion path.

This is not a certification that no advice is needed — it is a deliberate narrowing of the
surface so the remaining obligations are the ordinary kind. Encryption at rest does **not**
remove GDPR obligations: pseudonymous ciphertext is still personal data. What changes:

- **Lawful basis** becomes consent, which the opt-in design supports directly.
- **A Cloudflare DPA** is required, as they become a processor.
- **Deletion** must be a real path: an in-app "delete my cloud data", plus a documented
  route for a request arriving by email against an opaque id.
- **Residency** is answered by the EU bucket above.

### The privacy policy is not updated yet, deliberately

`site/privacy/index.html` needs edits to **What we collect**, **What we don't collect**
(which currently claims more than will remain true), **Third-party services** (Cloudflare
R2 joins it as a processor), and **Data deletion**.

**Children** needs re-reading but probably not rewriting: with photos staying in
user-owned storage, no account, and no readable content, this feature adds no
child-specific collection. Had we hosted the images, that section — and the App Store
privacy labels — would have needed real work.

Those edits should land **with the feature, not before it**. Publishing a policy that
describes collection which is not yet happening is its own inaccuracy.

## Still open

1. The recovery-code format and exactly where it is shown — once at opt-in is decided;
   whether it can be re-displayed later is not.
2. Quota numbers: per-id storage cap, object-size cap, rate limit. These are abuse
   controls now, not photo controls.
3. Whether sharing rides this transport at 1.0.4 or stays on the existing share-link
   surface. Sharing needs a fresh per-share key in the URL **fragment** (never sent to the
   server) and lifecycle-rule expiry, but it does not otherwise depend on sync landing.
4. Whether the photo archive is also the *within-ecosystem* mechanism on Android, or
   whether Android additionally mirrors photos to a Drive app folder the way iOS already
   uses its iCloud container. The archive alone is the smaller answer and probably enough.

**Closed:** whether legal review is warranted. There is no budget for it, so the design
was narrowed until the answer is no — see the Legal section. If a later change puts
user-generated content back on our storage, that question reopens with it, and this is the
line to cite.
