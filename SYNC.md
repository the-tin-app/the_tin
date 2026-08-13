# Sync — options and a recommendation

**Status:** proposal, 2026-08-13. No code. **Deferred to a 1.0.4 concept** by Tomas, who
has not read it yet — so nothing below is agreed. Written because there was no design doc
at all, and the last conversation produced constraints rather than a decision. The
recommendation at the bottom is one opinion.

1.0.3 is unaffected either way: it is a live TestFlight train and the store version has
not been created, so no sync work was ever going to reach it.

## What ships today is a backup, not a sync

`BackupService` + `ICloudBackupStore` write **one snapshot file** to the user's own
iCloud, and `workers/tin-backup` serves the catalog side. The snapshot is
**last-writer-wins over the whole file**.

That has already destroyed data: two devices, each holding a valid tin, and the second
write silently discarded the first one's cards. A conflict guard and a
"newer backup from another device" banner now exist in Settings, which turns silent loss
into a prompt — it does not make the file mergeable.

Three failures are known and recorded, and they are all *merge* failures, not transport
failures:

- **Deletions need two paths.** The change feed is once-only, so a delete that is missed
  is missed forever. Reconciliation belongs on *pull*, not on foreground.
- **Seeding is seed-only.** Anything predating sync is never uploaded, so a
  newly-syncing type strands every existing record. This is universal, not a one-off.
- **The no-op-write skip needs `.sortedKeys`.** Without deterministic encoding, every
  write looks like a change and the skip never fires.

## Constraints

From Tomas, 2026-08-12 — these are hard, not preferences:

1. **Cost is the limit.** Zero funding, zero sponsors, paid personally. "I am against
   firebase if the cost is too crazy."
2. **He must not be able to read anyone's collection** without something specific from
   them — a key. Encrypted in transit and at rest.
3. **He does not want to host user data**, explicitly because of data-privacy
   obligations including deletion requests.
4. **Sharing is key-gated**, and opt-in sharing is acceptable.

## The trilemma

This is not a tiebreak between otherwise-equal designs — it *is* the decision, and
everything else follows from it. Three properties, and only two are available at once:
**cross-platform reach**, **hosting nothing**, and **automatic sync**.

|  | Cross-platform | Hosts nothing | Automatic | Cost scales with users? |
|---|---|---|---|---|
| **A. Mergeable iCloud document** | ✗ (export/import only) | ✓ | ✓ (iCloud speed) | **No** — £0 flat, it's the user's iCloud |
| **B. CloudKit private database** | ✗ (permanent) | ✓ | ✓ (best polish) | **No** — Apple's quota, not ours |
| **C. E2EE blob on the existing R2/Worker** | ✓ | ✗ (hosts ciphertext) | ✓ | **Yes** — storage + egress per user |

That last column is the one to read against constraint 1. **A and B cost the same at ten
users and at ten thousand; C does not.** C is the only design here whose bill grows with
success, which is exactly the property to be suspicious of when the money is personal and
there is no funding — it is the same shape as the Firebase objection, even though the
per-user amount is much smaller.

CloudKit buys polish and costs Android permanently. The user's-own-file design keeps a
cross-platform escape hatch and costs automatic-ness across ecosystems. There is no
option that gives all three.

Encryption narrows constraint 3 but does not delete it: ciphertext tied to a device is
still personal data, so a deletion request still has to be honoured. What it *does* buy
is that honouring it is `DELETE <object>` and there is no account to unwind — with no
sign-in, the key is the only identity, and there is nothing else to erase.

Worth stating plainly: **C is the only option that reaches Android**, and B is already
parked (2026-07-31) for exactly that reason.

## Recommendation: build the merge layer, defer the transport

The merge semantics are identical in all three options, and the merge layer is what the
data-loss bug actually needs. It is also the only part that can be built without
answering the hosting question. So build it first and let the transport decision wait
for the Android decision, which is a product call and not an engineering one.

**The merge layer** — turn the snapshot into a mergeable document:

- Per-entry `id` + `modifiedAt`; last-writer-wins **per entry**, never per file. This
  alone ends the two-device data loss.
- **Tombstones** for deletes, with reconcile on pull. Both deletion paths, per above.
- Seeding folds **everything**, not just records created after sync was switched on.
- Deterministic encoding (`.sortedKeys`) so the no-op-write skip works at all.

Once the file merges, option A is nearly free: the same document in the user's own iCloud
*is* sync, at iCloud propagation speed, for £0, hosted by nobody, unreadable by Tomas,
with no deletion obligation. It also degrades to a plain encrypted file a user can carry
to another platform by hand — which is the honest Android answer until C is chosen.

**If Android becomes real**, C reuses infrastructure that already exists: a Cloudflare
Worker, R2, and App Check are all in the repo and already paid for. A tin is small JSON;
at current user counts the marginal cost is very likely negligible, but **that number
should be measured before it is promised** — the cost constraint is the hard one and this
doc should not hand-wave it. Per the table above, C is also the one option whose bill
scales with adoption, so the figure that matters is not today's but the one at 10× the
current install base.

## Sharing

Opt-in and key-gated, per constraint 4. Sharing does not need the sync transport: a
shared list is already a separate surface with its own vocabulary (see `DESIGN.md §6` —
the shared page writes for a stranger, not a cardholder). Keep it that way; do not let
sharing and sync become one feature.

## Testing note

The iPad on iOS 18 cannot verify *any* iCloud feature — iCloud Drive and iMessage are
wedged on it too, so it is a device-level fault and not evidence about our code. Any
two-device sync test needs a second real device or two simulators, not that iPad.

## Open questions for Tomas

1. **Does Android matter within the next two releases?** This is the whole decision. Yes
   → C. No → A.
2. Is hosting *ciphertext* acceptable, given a deletion request is one object delete and
   there is no account behind it?
3. If C: what is the actual monthly ceiling you will accept, so it can be measured
   against a real number rather than argued about?
