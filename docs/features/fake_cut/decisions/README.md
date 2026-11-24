# Decisions - Virtual Cut

Append-only. A reversed decision keeps its text and gains a `Superseded by`
line. Decision numbers are never reused.

| ID | Decision | Status |
| --- | --- | --- |
| [0001](0001-pair-by-recorded-source-name.md) | Pair a project by its recorded source name | accepted |
| [0002](0002-plan-order-timeline.md) | The timeline is the plan order, never sorted or de-duplicated | accepted |
| [0003](0003-snapshot-plan-by-content-signature.md) | An open plays a snapshot plan keyed by content | accepted |
| [0004](0004-fvp-blocks-standalone-source-in-merge.md) | fvp blocks standalone cutting; a merge plays the source | accepted |
| [0005](0005-active-plan-is-an-explicit-state.md) | Activation is explicit; no bound-plan fallback | accepted |
| [0006](0006-scoped-background-audio-stand-down.md) | 副音 stands down only for the cut's own file | accepted |
| [0007](0007-explicit-directory-index.md) | The project index is directory-cached and explicitly invalidated | accepted |
| [0008](0008-show-losslesscut-tradeoffs.md) | Show LosslessCut tradeoffs as localized notices | accepted |
