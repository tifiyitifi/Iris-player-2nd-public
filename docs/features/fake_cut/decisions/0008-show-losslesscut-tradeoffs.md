# 0008 - Show LosslessCut tradeoffs as localized notices

- Date: 2026-11-23
- Status: accepted
- Private history: feature work (no single commit)
- Supersedes: none
- Superseded by: none

## Context

LosslessCut projects carry facts the player cannot "fix" without lying about
the export: ignored markers, deselected ranges, clamped ranges, sub-200ms
ranges, a recorded source name that differs from the playing file, and blocked
backends. Silently swallowing them produced "why did my cut change?" reports.

## Decision

`FakeCutPlanBuilder` emits typed notices; `FakeCutTexts` renders one localized
line per notice, and preflight blocked reasons each have their own localized
line. A clean plan shows none. No user-facing string is built by concatenation;
new keys ship in both ARB files.

## Consequences

- The tab can explain a plan without exposing parser internals.
- Adding a notice kind requires en + zh text in the same change, plus a test.
