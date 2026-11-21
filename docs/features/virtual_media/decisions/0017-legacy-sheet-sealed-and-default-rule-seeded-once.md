# 0017 - The legacy sheet is sealed and the default rule is seeded once

- Date: 2026-11-21
- Status: accepted
- Private history: `f8f370a8`, `48473b9f`
- Superseded by: none

## Context

The old More-menu control center mixed rule editing, a session card, a preview
resolve and a duration scan. Rule CRUD moved to the metadata-driven manager page,
but the old path stayed reachable and could start a second session.

## Decision

`VirtualMediaGate.legacySheetEnabled` is permanently `false`. The file stays as
dead code and must not be re-enabled. The first-run default rule
(`_dirs_as_virtual`) is seeded once, guarded by the AUX marker
`virtualmedia.defaultsSeeded`, and is never resurrected after the user deletes
it.

## Consequences

- The old sheet, its preview, scan and session cannot execute.
- A deleted default rule stays deleted.
- The default rule is deletable like any other.

## Rejected alternatives

- Keeping the sheet behind a feature flag.
- Re-seeding the default rule on every launch.
- Migrating the old sheet's session state.
