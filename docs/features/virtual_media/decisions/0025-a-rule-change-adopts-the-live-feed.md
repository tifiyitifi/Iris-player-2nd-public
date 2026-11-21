# 0025 - A rule change adopts the live feed instead of waiting for the next file

- Date: 2026-11-21
- Status: accepted
- Private history: feature work (no single commit)
- Superseded by: none

## Context

The More-menu folder toggle writes a rule, and the list re-resolves. The
PLAYER, however, was only re-evaluated when the next `advanceEntry` ran: the
video that was playing kept its single-file feed (no dual time, no segment
marks, no cross-segment advance) and the merge only appeared after next/prev.
The product contract is "立刻使用就立刻是虚拟合并，继续当前进度" — turning it on
must apply to the video on screen, not to the next one.

Re-entering through `startSession` would call `player.open` on the same
physical file again: a re-open restarts the position/audio (a visible flash),
which the same contract forbids ("只改显示层").

## Decision

`VirtualMediaController.adoptLiveSession` attaches the VM timeline to the
already-open feed WITHOUT feeding the player:

- it writes only the session state (item, segment index, sibling queue, queue
  index) and marks the current queue file as the expected segment, which is
  exactly what `isActive` tests;
- it never touches the play queue, autoplay, `media_nodes` progress or the
  engine: the position is already correct, so nothing needs re-opening;
- the intra-segment seed for anchors comes from the live progress mirror (at
  most one tick stale); the 5s anchor timer overwrites it, and anchors are
  diagnostics only (resume uses each file's own progress);
- it REFUSES when a session/feed already owns the timeline or when the play
  queue has moved off the file the caller acted on. A refused adoption leaves
  ordinary single playback, so the next feed merges instead.

Entry point: `PlaybackProviderRegistry.adoptCurrentFeedAsVirtual`, dispatched to
whichever provider owns the feed (scenario stream or tag snapshot). The tag
path re-resolves its snapshot first, because the cached groups predate the rule
change.

The player hooks subscribe to the VM session (`item?.scopeKey`) in addition to
reading `isActive`, so adoption/exit repaints the title, dual time, scrubber and
segment marks even while paused (no position tick would wake the hook).

The opposite direction is keyed on the LIVE segment and the FRESH rules, not on
the toggled rule's id: a folder can be carved out of a merge owned by a
recursive rule above it, and that session must stop too.

## Consequences

- "Use" is visible on the current video within a frame of the session store
  change; playback is not interrupted.
- The scenario bar title's `[cur/total]` is republished after adoption, because
  the merged list changed the row index.
- No new persistence: adoption is derived state, rebuilt on the next feed.

## Rejected alternatives

- Re-feeding with an explicit `initialLocalMs`; it still re-opens the file and
  interrupts playback.
- Adopting on ANY rule change (e.g. the editor, settings import); it would
  mutate the current picture behind the user's back for edits unrelated to it.
- Adopting the provider's current item regardless of the file the user toggled;
  a frozen popup could then merge a different file than the one the button
  named.
