# 0023 - Non-recursive wins, and one enabled rule per folder

- Date: 2026-11-21
- Status: accepted
- Private history: feature work (no single commit)
- Superseded by: none

## Context

Overlapping rules are legal and independent. A folder can be covered by a
recursive rule on a parent AND by a non-recursive rule on itself. Without an
order, "use" and "not use" would be ambiguous. The product requirement is:

- non-recursive wins over recursive;
- explicit `specifiedDir` wins over name `patternDir` ("说用就用，说不用就用");
- one enabled non-recursive rule per exact path.

## Decision

Per file, only enabled rules are considered, in four tiers, first covering
tier wins:

1. `specifiedDir` (non-recursive, explicit path)
2. `patternDir` (non-recursive, name)
3. `specifiedDirRecursive`
4. `patternDirRecursive`

Inside one tier `notUse` wins (an explicit exclusion is the safer reading).
Tier 1 is additionally guarded by a uniqueness rule: at most one ENABLED
`specifiedDir` rule per canonical path, checked by path-set intersection (a
rule may union several paths). The editor save and the manager card switch
both funnel through the same guard and ask which rule keeps `enabled`.

This is why a non-recursive `notUse` on `Shorts/1` only carves out `Shorts/1`:
the parent and its subdirectories are still decided by the recursive tier.

## Consequences

- The folder toggle can exclude one folder without editing the parent rule.
- Two enabled same-path rules cannot silently fight.
- `failByKey` and the overlay see exclusion-consistent results.

## Rejected alternatives

- A rule `priority` integer (the model deliberately has none).
- "use always wins"; it would make an explicit exclusion unexpressible when a
  loose pattern also matches.
