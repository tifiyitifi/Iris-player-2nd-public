# 0001 - Rules are data and have no priority

- Date: 2026-11-21
- Status: accepted
- Private history: `48473b9f`
- Superseded by: none

## Context

The first virtual-media versions embedded grouping decisions in playback code
and let two rules claim the same directory. Which rule won depended on load
order. A reader who edited a rule could not predict which files would merge.

## Decision

A rule is a saved record. The resolver interprets it. There is no priority
field, and two rules that cover one directory both produce items.

## Consequences

- Grouping is a pure function of the rule and the covered files.
- Duplicated items are visible and are the user's choice to resolve.
- Closing a rule is a data edit, not a code change.

## Rejected alternatives

- A numeric priority that silently drops the losing rule.
- "First rule wins" arbitration.
- Hard-coded directory rules for common layouts.
