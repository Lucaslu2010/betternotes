# Nearby sync: conflict and delete policy

Date: 2026-10-01. Status: design approved by Kenny in conversation; this spec awaits review.
Decisions in this document are Kenny's; the mechanism is Claude's proposal.

## Goal

Settle what nearby sync does when both devices edited a notebook, when a
notebook is deleted, and where conflict copies end up, so a library never
loses data silently and the Notes list stays clean.

## Decisions

1. **Both devices edited the same notebook:** the user chooses, in a setting.
2. **Moving a notebook to Trash** syncs (it already does, as an ordinary edit).
   Each device keeps its own Trash.
3. **Permanent delete** is sent to the other device, which asks before
   deleting. It never deletes silently.
4. **Conflict copies** are created already archived, so they appear in the
   Archive view and not in Notes.

## Current behaviour (read from the code, 1 Oct 2026)

- `NearbyMergeDecision.decide` compares local, incoming and last-shared
  hashes. If both sides changed, the receiver saves a conflict copy
  (`saveConflictCopy`), or on the first half of an exchange keeps its own
  version as a copy and adopts the sender's (`preserveLocalAndReplace`).
- Conflict copies come from `CloudTranslator.importArchiveData(conflictSuffix:)`,
  which appends " (from <device>)" to the title. They are not archived;
  `NearbyConflictCleanup.organizeLegacyCopies` archives such titles later.
- `trashedAt` is part of the synced archive, so Trash travels as an edit.
- Nothing carries a permanent delete. `NearbySyncPackage` lists only
  existing notebooks; with a baseline and no local copy, `decide` returns
  `.keepLocal`, so the other device keeps its copy and the libraries drift.

## Design

### 1. Conflict-copy placement (first, smallest)

`importArchiveData(conflictSuffix:)` sets `isArchived = true` on the copy it
creates. Normal imports and replacements are unchanged. The sync sheet
summary reads "N conflict copies saved to Archive". The legacy cleanup stays
for notebooks already in a library.

Risk: an archived copy is easy to miss. The summary line and the existing
Archive view are the mitigation; no extra badge in this change.

### 2. Conflict setting

New persisted setting `NearbyConflictPolicy`, shown in the nearby sync
sheet on both platforms: "If both devices edited the same notebook".

| Option | On a conflict |
|---|---|
| Keep both (default) | Today's behaviour, with the copy archived (section 1). |
| Newest edit wins | The notebook with the later `modifiedAt` replaces the other. The older edit is lost. |
| Always prefer iPad | The iPad's version replaces the Mac's. The Mac's edit is lost. |
| Always prefer Mac | The reverse. |

- `decide` gains a `policy` input and the local and incoming `modifiedAt` and
  device role. The "both changed" branch returns `replaceLocal` or
  `keepLocal` when the policy picks a winner; the existing branches are
  untouched. Winning policies are applied only in the "both changed" case,
  never to a one-sided edit.
- The rules are device-neutral, so two devices with the same setting reach
  the same result. The package carries the sender's policy; when it differs
  from the receiver's, the receiver uses **Keep both** for that exchange and
  the sheet shows "The other device uses a different conflict setting".
  Mismatch therefore never loses data.
- The non-default options say in the setting's footer that the losing
  edits are discarded.
- Open-notebook deferral already applies to any decision that replaces the
  local notebook and covers the new outcomes.

### 3. Permanent delete

- **Recording.** Every user-initiated permanent delete (single delete, Empty
  Trash, and the Mac equivalents) records the notebook's `stableID` and the
  deletion date in a persisted tombstone list. Deletes made by sync itself
  (replacement, accepted remote delete) do not record one.
- **Sending.** Protocol version 5. `NearbySyncPackage` gains
  `deletions: [NearbySyncDeletion]` (id, title, date, and the notebook's
  last-shared hash with this peer). Both paired devices must run this build;
  a v4 package is rejected with the existing `unsupportedVersion` error.
- **Receiving.** For each deletion whose notebook still exists locally:
  - If the local hash equals the last-shared baseline (unchanged since the
    last sync), queue a confirmation: "<Device> permanently deleted
    '<title>'. Delete it here too?" with Delete or Keep. Delete removes it
    and clears its baseline; Keep records the decision so the question is not
    asked again, and the notebook stays here.
  - If the notebook was edited locally since the baseline, keep it and do not
    ask; the sheet notes "Kept '<title>': edited here since it was deleted".
  - If the notebook no longer exists, or is in Trash, acknowledge and do
    nothing.
- **Never silent.** Nothing is deleted until the user answers. Unanswered
  deletions stay queued and are offered again at the next exchange.
- **Acknowledgement.** The sender drops a tombstone once the peer
  acknowledges it (answered either way). Tombstones also expire after 90 days.
- A kept notebook is not re-sent as a conflict: the deleter has a baseline
  and no local copy, which `decide` already treats as `.keepLocal`.

## Components touched

`NearbySync.swift` (package, `decide`, receive loop, sheet), `CloudTranslator.swift`
(archive flag on conflict copies), `LibraryView.swift` and `MacLibraryView.swift`
(record tombstones at the delete sites), a new small `NearbyDeletionLog`
persisted store, and a confirmation presented by the sync sheet on both
platforms.

## Testing

- Unit: `decide` for every policy and branch, including mismatch fallback,
  one-sided edits unaffected, and open-notebook deferral of winning outcomes.
- Unit: conflict copies are archived and the original is not.
- Unit: tombstone recorded for a user delete, not for a sync delete;
  receiver decision table (unchanged, edited, absent, trashed); Keep is
  remembered; acknowledgement clears the tombstone; v4 rejected.
- UI: the setting is present and persists; a queued deletion shows the
  confirmation (simulated peer injection if the coordinator allows it).
- Device: a real iPad and Mac pair, added to `RELEASE_CHECKLIST.md`:
  conflicting edit under each policy, permanent delete answered Delete and
  Keep, and a delete on a notebook edited on the other side. This is the part
  that cannot be proved in the simulator.

## Out of scope

Syncing more than one peer, merging edits inside a notebook, undoing an
accepted permanent delete, and changing what Trash syncs.

## Open items

- Wording for the confirmation and the setting footer needs en, zh-Hans and
  zh-Hant strings.
