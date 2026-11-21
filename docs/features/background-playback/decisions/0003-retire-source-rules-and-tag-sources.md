# 0003 - Retire the source-rule subsystem and the tag scenario sources

- Date: 2026-10-13
- Status: accepted
- Private history: `d716706a`, `06de08c4`, `d396ea47`, `e5c50ca8`, `625ec3e3`
- Superseded by: none

## Context

The rule table had grown a staged editor, a manager, a banner and a cache. The
tag scenario source then duplicated what the tag view already did. Both were
reuse of a general mechanism that fought its own invariants.

## Decision

- v48 drops `bg_source_rules` and its DAO/repository/resolver/cache/editor.
- v49 deletes the tag scenario sources and the `tag_id` column.
- The only live rule is the reserved tag view from `0002`.

## Consequences

- `invalidateSourceRules()` and the `bg_src_*` ARB keys are dead code kept for
  rollback.
- Any future "custom source" request starts from the tag view, not from a new
  table.

## Rejected alternatives

- Keep the rule table for "custom sources". It kept re-introducing a second
  membership model beside the tag view.
