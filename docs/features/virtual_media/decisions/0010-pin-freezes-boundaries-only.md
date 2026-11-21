# 0010 - The pin freezes boundaries, not membership

- Date: 2026-11-21
- Status: accepted
- Private history: `7629d867`, `28a7c1bc`, `29c32d15`
- Superseded by: none

## Context

A desktop physical delete re-derived the affected rule, so one deleted file
re-chunked every item in the rule. A snapshot-based fix kept the old chunk shapes
but also kept stale metadata, and it dropped groups that had become infeasible.

## Decision

The pin stores chunk boundaries and removed keys only. Members are re-read from
the current library by `mediaKey`. Infeasible groups stay in the pin. The freeze
covers every rule that covered the deleted file, is session-scoped, and lifts on
restart, source change, rule change or explicit refresh. A management preview
resolves with `applyPin: false`.

## Consequences

- Only the affected chunk changes shape.
- A renamed or moved member shows its fresh metadata.
- The yellow failure mark survives a freeze.

## Rejected alternatives

- Rule-scoped invalidation.
- A membership snapshot.
- Dropping infeasible groups from the pin.
