# 0002 - Picture adjustment is session-scoped, not persisted

- Status: accepted
- Date: 2026-11-22

## Context

A mirror or rotation is a viewing adjustment for the picture on screen now, not
a preference. Persisting it would make every later video mirrored until the user
remembers to reset, which reads as a bug. The project already has a runtime-only
precedent (`PlayerUiStore` is a `Store`, not a `PersistentStore`).

## Decision

`VideoTransformState` lives in a plain runtime `Store`. It is never written to
Drift/AUX, never mirrored into `AppState`, and never serialized. It resets when
the media changes and on app restart.

## Consequences

- No schema change, no meta-settings row, no parity tests.
- The panel's reset action is the only explicit clear.
- A future "remember this" request would be a separate, explicit feature.

## Rejected

- Meta-settings persistence: the "every video stays flipped" trap.
- Per-file profiles: out of scope for a first cut.
