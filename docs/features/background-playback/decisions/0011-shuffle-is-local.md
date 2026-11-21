# 0011 - Shuffle for the Sub Audio pool is local

- Date: 2026-10-11
- Status: accepted
- Private history: `82784a89`, `73859ef1`, `e5c50ca8`
- Superseded by: none

## Context

The pool is a tag view shared with the foreground browser. Writing a shuffle
order into that view reordered the foreground browser, and a later index fix
still played the wrong file.

## Decision

Shuffle is a local, deterministic permutation by seed, applied after the tag
view resolves. It never writes order into the shared view. `virtualIndex` is
renumbered after the shuffle so a row position and a queue index agree.

## Consequences

- The foreground order is stable whatever the background does.
- A shuffled queue is unaffected by a reordered pool with the same members.

## Rejected alternatives

- Reuse the scenario shuffle. It reordered the foreground browser and produced
  wrong-file plays (`e5c50ca8`).
- Sort the shared view in place. It is not the background's view to mutate.
