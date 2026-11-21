# 0012 - The gate makes the feature absent

- Date: 2026-11-21
- Status: accepted
- Private history: `48473b9f`, `76b6022b`
- Superseded by: none

## Context

The metadata-driven settings stack replaced the legacy secure-storage settings.
Virtual Media depends on it for rule storage and settings rows. A half-visible
feature showed entries that could not work.

## Decision

`VirtualMediaGate.enabled` is `useMetadataSettings` and not
`useLegacyStoragePersistence`. When it is off, the feature is absent: entries are
hidden, commands are explaining no-ops, and every `virtualmedia.` settings row is
filtered by `DefVisibility.registerPrefix`.

## Consequences

- No dead entry point is reachable.
- The gate is read at startup, so it is a wiring fact rather than a widget check.
- The legacy sheet is sealed independently (0017).

## Rejected alternatives

- Showing the feature disabled with a banner.
- Reading the legacy settings blob as a fallback.
