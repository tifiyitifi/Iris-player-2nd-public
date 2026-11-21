# 0012 - Alignment anchors come from the two real durations

- Date: 2026-10-17
- Status: accepted
- Private history: `2a17137e`, `456d9b34`, `fd399a31`, `472d59b9`, `838c15f9`
- Superseded by: none

## Context

A persisted "default alignment mode" competed with the file durations. The
dialog offered options, then the options were removed, then a manual tab was
restored. The same day, a stale pinned offset produced a phantom drift across a
cross-file continuation.

## Decision

The anchor is derived from the two real durations, with no stored default:
background at least as long as the foreground maps to one clock; a shorter
background whose remainder fits is tail-anchored; otherwise the background
starts at 00:00 at the current foreground position. The automatic rule is
explained read-only. The manual re-align tab stays and the tabs stay visible
while Sub Audio is inactive.

## Consequences

- A continuation keeps the pinned offset instead of drifting.
- There is no "default alignment" setting to get out of sync.

## Rejected alternatives

- Persist a default alignment mode. It fought the real durations.
- Offer the automatic rule as a menu. It was replaced by an explanation
  (`456d9b34`) and the manual tab was kept (`fd399a31`).
