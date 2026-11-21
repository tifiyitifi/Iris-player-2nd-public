# 0014 - A real queue end re-activates; it does not replay

- Date: 2026-10-29
- Status: accepted
- Private history: `9eadfde9`, `a2b088b7`, `19d63eb2`, `a0c3a984`, `75ba1cd5`, `6e96413e`, `1b444e0b`
- Superseded by: none

## Context

Handing the pair back at the end of a queue was fixed six times. One fix
treated every double-play collision as a queue end, so the pair handed back
while playable candidates remained. A direction guess from sparse ids read a
wrap as a backward move. A later fix drew a play icon on a button that did
nothing. Eleven days earlier the same area had concluded the opposite: a
blocked next at the pool end should stop, not replay.

## Decision

Hand-back is a derived pair state, not a flag: the pair is out of scope, the
queue is ended, or the run is exhausted. A **real** queue end re-activates on
the next gate press. A collision with the foreground file is not a queue end.
Queue direction comes from the move stamp the queue itself writes, not from id
gaps. The earlier "stop, do not replay" answer still holds for a real play at
the end; it does not apply to the hand-back branch.

## Consequences

- The next button at a real end is a re-activation, not a dead button.
- A collision never latches a terminal state.
- The two opposite answers are documented together instead of one silently
  overwriting the other.

## Rejected alternatives

- Treat a collision as the end of the queue (`a2b088b7`).
- Infer direction from sparse ids (`19d63eb2`).
- Draw a play icon without wiring the action (`6e96413e`).
