# 0002 - The candidate pool is the reserved tag view, and it is never VM-merged

- Date: 2026-10-11
- Status: accepted
- Private history: `82784a89`, `6afffc08`, `d396ea47`, `e5c50ca8`
- Superseded by: none

## Context

The candidate source is the "audio library" gesture: tag a video you have
watched, and a later video can use its audio. The same reserved tag was
modelled three times before: a JSON source list, a rule table, and a scenario
tag source. Each reuse collided with the mechanism it borrowed.

## Decision

The pool is the active membership view of the reserved system tag
`TagSystemKind.backgroundVoiceCandidate`, resolved through `TagViewResolver`
with `withVmOverlay: false` and `ignoreScenario: true`. The foreground file is
a legitimate member and is excluded only at selection time. Shuffle is a local,
deterministic permutation by seed; `virtualIndex` is renumbered afterwards.

## Consequences

- One source rule, with no rule table and no source editor.
- The foreground browser order is never touched by a background shuffle.
- The queue is built from real files, not from VM-merged members.

## Rejected alternatives

- `bg_source_rules` (v28). A whole sub-UI grew around it; retired in v48.
- A scenario tag source (v47). It duplicated the tag view; retired in v49.
- Merging the pool through the shared scenario resolver. It made members
  disappear under the VM merge (`6afffc08`).
