# 0010 - P is a pure alignment offset handle

- Date: 2026-09-14
- Status: accepted
- Private history: `230b77a7`, `64afb45b`, `6c5a05f8`, `9df05b2e`, `185d4a29`, `323b0237`, `4062f88e`, `8bd705be`, `512af46f`, `85ba7bbd`, `ed42c848`, `6ba464b5`
- Superseded by: none

## Context

The P handle was redefined more than a dozen times in two days. It was an
offset handle, then a whole-window mover, then a window lengthener, then a
pinned-end offset spender. The `-??:??` readout flipped direction with it. An
A/B snap feature was added and reverted the same day.

## Decision

P is a pure alignment offset handle. Moving it changes the offset and leaves
A/B alone when there is room. When an A/B end pins, the gesture consumes the
pile and then translates. Readouts freeze while a gesture is in progress. Slide
room comes from the foreground bounds, not the background bounds.

## Consequences

- The renumbering rule for `virtualIndex` and the readout are separate from the
  span math.
- A new drag mode needs a golden test before it ships.

## Rejected alternatives

- P moves the whole A-B window (`230b77a7`, restored in `64afb45b`).
- P grows the window by spending unused background time (`185d4a29`, replaced
  in `323b0237`).
- The pinned end grows its own `-??:??` (`8bd705be`, reverted in `512af46f`).
- The far end follows the drag (`85ba7bbd`).
- A/B endpoint snap (`ed42c848`, reverted in `6ba464b5`).
