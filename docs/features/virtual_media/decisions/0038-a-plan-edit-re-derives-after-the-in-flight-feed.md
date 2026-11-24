# 0038 - A plan edit re-derives after the in-flight feed settles

- Date: 2026-11-24
- Status: accepted
- Private history: fix for ADR 0034
- Supersedes: none
- Superseded by: none

## Context

ADR 0034 compares the opened session's content signature with the range the group
displayed and, on a mismatch, asks for one live re-derive. The first
implementation called `PlaybackProviderRegistry.refreshLiveVirtualGroups()`
directly from the player hook, during the open. Two facts made that request a
no-op:

- the resolver/provider group caches are keyed by the SCENARIO signature
  (definition + `playbackVersion` + the VM revision), not by the `.llc` content,
  so an edited plan did not change the cache key;
- `resegmentLiveFromGroups` deliberately refuses while a feed is in flight
  (`_feedInFlight` / `transitioning`), and the request was issued exactly inside
  that window. A feed that lands afterwards would overwrite the replaced item
  anyway.

The player therefore played the fresh EDL while the merged duration, totals and
scrubber kept the old length until an unrelated invalidation (a rule edit, the
tab refresh, a rescan or a restart).

## Decision

A plan edit is announced and re-derived like any other cut-plan change, but the
live re-segment waits for the open to settle:

1. `notifyCutPlanChanged()` bumps the VM revision and `playbackVersion`, and
   refetches open queue surfaces (ADR 0035). The scenario signature therefore
   changes and both group caches miss.
2. `VirtualMediaController.afterCurrentFeedSettled(...)` runs the re-segment now
   when idle, or in `_feedCurrent`'s `finally` after `_feedInFlight` clears.
   Replacing the item mid-feed is never attempted.
3. The re-derive is forced (`refreshLiveVirtualGroups(forceRefresh: true)` →
   `vmGroupsForLiveSegment(forceRefresh: true)` → `resolveVmGroupsFor(
   forceRefresh: true)`) so a signature that happens to agree still cannot serve
   the pre-edit groups. In tag mode the snapshot is revalidated first.

## Consequences

- Editing the active plan converges on the next open of that segment: the
  picture, the merged duration and the scrubber agree again, without reopening
  the media twice.
- The live item is replaced only after the open, so the feed cannot clobber the
  re-segment.
- The request is idempotent: the next group carries the fresh signature.
- A forced re-resolve runs at most once per edited open; it does not run on
  every open.

## Rejected alternatives

- Force a re-resolve from inside the open: `resegmentLiveFromGroups` refuses
  there, and a later feed would overwrite the result.
- Drop the `_feedInFlight` guard for this path: the in-flight feed's
  `store.replace` would race the re-segment.
- Rely on `mtime:size` in the cache key: a touched-but-unchanged plan would
  re-derive for nothing.
