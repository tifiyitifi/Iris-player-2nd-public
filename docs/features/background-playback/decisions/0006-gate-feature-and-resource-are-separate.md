# 0006 - Gate, feature switch and resource ownership are separate axes

- Date: 2026-09-17
- Status: accepted
- Private history: `2b8c2f63`, `20d5bb2d`, `18a853d1`, `1c69a715`
- Superseded by: none

## Context

The gate semantics were redefined four times in a day. The same boolean was
read as "the feature exists", "the user wants it", "it is running" and "it owns
the controls". Readers reported a pair that was "not active" while the engine
was audible, and a button that drew "play" but did nothing.

## Decision

Three axes, kept separate:

- `enabled`: the subsystem exists and can be configured.
- `gateOpen`: the user's permission to sound.
- scope: which media the pair applies to.

A pair is in effect only when enabled, gate open, in scope, not exhausted and
not at a terminal queue end. `stopGate` is a pure stop. `armRunStopped` arms
without playing. `keepWarmPlayer` keeps an idle engine alive for launch.

## Consequences

- A cold load arms from `startArmed` but leaves the gate shut.
- A deactivation returns controls and picture to the foreground.
- Settings stay reachable while the gate is closed.

## Rejected alternatives

- One boolean for all four meanings.
- Treating "armed" as "playing".
- A gate-closed bypass that greyed every setting row; it was narrowed to the
  routing rows only.
