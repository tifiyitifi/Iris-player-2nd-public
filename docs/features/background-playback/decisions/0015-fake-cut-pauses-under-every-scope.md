# 0015 - A fake cut pauses Sub Audio under every scope

- Date: 2026-10-26
- Status: accepted
- Private history: `1b0b2f50`, `993cc06c`, `9ab1f27f`
- Superseded by: none

## Context

A fake cut is a synthetic timeline over one file. A pre-check claimed Sub Audio
could not coexist with it, but the check read `enabled`, which is also true for
an armed-but-closed gate, so it refused forever. Later, the remembered cut plan
was treated as the cut that was actually open, so the pair resumed against the
wrong timeline.

## Decision

A fake cut pauses Sub Audio for that media under every scope, including the
anchor. Resume happens only if the run was actually sounding. The routing
memory survives the cut and two cuts in a row keep the resume memory. The
binding is the file whose open actually adopted the cut, not the remembered
plan.

## Consequences

- A user pause is not resurrected by the cut ending.
- An explicit stop or a fresh enable clears the suspension.
- Entering, staying in and leaving a cut all exempt Sub Audio from stepping.

## Rejected alternatives

- The "cannot coexist" pre-check. It read `enabled` and refused permanently
  (`1b0b2f50`).
- Binding to the remembered plan. It resumed against the wrong cut
  (`9ab1f27f`).
