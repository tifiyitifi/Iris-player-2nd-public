# 0006 - An unknown duration joins and degrades

- Date: 2026-11-21
- Status: accepted
- Private history: `61d02592`, `60d4f2da`
- Superseded by: none

## Context

Two filters read "duration is null" differently. The overlong filter treated a
null as overlong and dropped the file; preflight sometimes hid the group. The
result was a merge that silently lost a member.

## Decision

An unknown or zero duration is never overlong and never excluded. The file joins
the group. Preflight then fails the whole group and the group degrades to
ordinary single rows with a visible failure mark.

## Consequences

- Nothing disappears silently.
- The group's failure is visible before play and is carried by `failByKey`.
- A later duration heal can make the group feasible without a rule edit.

## Rejected alternatives

- Dropping unknown members.
- Hiding the whole group.
- Fabricating a duration to keep the group.
