# 0005 - Rotate first, mirror second (display space)

- Status: accepted
- Date: 2026-11-22

## Context

Mirroring before or after a quarter-turn rotation gives different results. In
source space, a "horizontal" mirror after a 90-degree turn appears as a vertical
mirror on screen, which contradicts the label the user pressed.

## Decision

The composition order is fixed to rotate-then-mirror, everywhere:

- widget tree: `Transform( RotatedBox( surface ) )`,
- saved frame: `copyRotate` then `flipHorizontal` / `flipVertical`.

So "mirror horizontally" always means the screen's horizontal axis.

## Consequences

- The label matches the result regardless of rotation.
- Both the render path and the post-process must keep the same order; changing
  one alone is a bug.

## Rejected

- Mirror-then-rotate: source-space semantics that confuse the user after a turn.
