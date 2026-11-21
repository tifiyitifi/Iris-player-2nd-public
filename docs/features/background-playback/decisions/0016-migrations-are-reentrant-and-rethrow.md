# 0016 - Migrations are reentrant and rethrow failures

- Date: 2026-10-13
- Status: accepted
- Private history: `ed42c848`, `625ec3e3`
- Superseded by: none

## Context

v27 hard-coded a table name, so the `fg_percent`/`bg_percent` columns were
never added; a later migration had to repair databases already stamped past the
broken version. v48 swallowed a failed `DROP`, so the table survived while the
schema claimed it was gone. A migration that hides its own failure is worse
than a crash.

## Decision

Migrations are reentrant: guard on what exists, not on the version alone.
Failures are rethrown, never caught and ignored. A repair migration must fix
both a fresh database and one that was stamped past the broken step. Drop and
create steps must survive a re-run.

## Consequences

- A populated timeline stays usable after a re-run.
- A legacy table cannot survive a "successful" drop.

## Rejected alternatives

- Silent `try/catch` around DDL. It produced a schema that lied.
- Version-only guards. They skipped a database that had been stamped past a
  broken step.
