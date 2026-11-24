# 0035 - A cut-plan change re-groups without clearing scan bookkeeping

- Date: 2026-11-23
- Status: accepted
- Private history: feature work (no single commit)
- Supersedes: none
- Superseded by: none

## Context

ADR 0032 made activating or closing a cut an admission change: the live merge
must be re-segmented before the cut store's revision bump reopens the media. The
handler for that (`PlaybackProviderRegistry._onCutPlanChanged`) reused
`VirtualMediaService.notifyRulesChanged()`, the full rule-change fan-out. But a
cut has nothing to do with rules: `invalidate()` also dropped the rule cache,
the published preflight-fail map, the failed-group snapshots, the per-session
Shell-empty marks (`_shellUnsupported`) and the dismissed scan prompts
(`_dismissedScanScopes`). Toggling a cut therefore re-armed the Windows Shell
probe and the scan dialog for unrelated files, and re-read the rule table.

## Decision

`VirtualMediaService.notifyCutPlanChanged()` is the propagation for a cut-plan
change. It:

- bumps `_revision` (the derived-index signature includes it, so an in-memory
  index rebuilds with the new cut admission),
- clears `VmMembershipPin` (a re-group trigger),
- refreshes an ACTIVE tag view FIRST (its snapshot holds the merge groups the
  live feed and the queue list read),
- bumps `bumpPlaybackVersion()` and `notifyQueueRefetch()` — the two signals the
  rule path already proved are needed (player chrome/locate caches vs OPEN queue
  surfaces).

It deliberately does NOT clear the rule cache, the fail map, the failed-group
snapshots, `_shellUnsupported` or `_dismissedScanScopes`: none of them became
wrong because a plan was opened or closed.

`PlaybackProviderRegistry.onCutPlanChanged` (the installed handler) calls it and
then `refreshLiveVirtualGroups()`. `notifyRulesChanged` stays the propagation for
actual rule edits.

## Consequences

- Opening/closing a cut still re-groups every open surface immediately, but no
  longer re-arms the Shell probe / scan prompt for files already known, and does
  not re-read the rule table.
- The handler is unit-testable without the playback layer (`_ready` is false, so
  the live re-segment step is a no-op) while still exercising the propagation.
- A future cut-related change that DOES invalidate rules (none today) must use
  `notifyRulesChanged`, not this method.

## Rejected alternatives

- Keep `notifyRulesChanged`: cheaper to write, but it silently degrades scan
  behaviour and reloads rules for an unrelated event.
- Reuse `notifyDurationsChanged`: it persists a MEDIA CONTENT revision, which
  claims the media rows changed. A cut plan change must not invalidate every
  scenario's content signature on disk.
