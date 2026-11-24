# 0002 - One visibility seam writes both overlay flags

- Status: accepted
- Date: 2026-11-22

## Context

Visibility was written by two setters called one after the other:
`updateIsFullscreenDockPeeking(false)` then `updateIsFullscreenDockPinned(!pinned)`.
Every caller had to remember the pair, and the two flags mean different things to
different readers (`shown` is the OR of both). A caller that cleared `peeking`
but left a seed on produced a panel that could not be dismissed — indistinguishable
from a bug in the conceal path, which is how it was reported.

## Decision

`PlayerUiStore` owns three methods and nothing else writes these flags:

| Call | Effect |
| --- | --- |
| `showFullscreenDock()` | revealed now, no seed |
| `seedFullscreenDockOnEntry(reveal)` | entry state from `SideFullscreenBehavior` |
| `hideFullscreenDock()` | both off |

Each method performs a single `set`, and `isFullscreenDockShown` is the one
reader predicate.

## Consequences

- No half-open state can be observed between two writes.
- New call sites cannot invent a fourth combination.
- The old setters were removed, so a stale caller fails to compile rather than
  silently leaving a flag behind.

## Rejected

- **Keep the two setters and document the pairing.** The failure mode is silent
  and only shows up as "the panel will not close".
- **Rename `isFullscreenDockPinned`.** It is a Freezed field: codegen churn for
  no behavioural difference while it still means "the entry seed".
