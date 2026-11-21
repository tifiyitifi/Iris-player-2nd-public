# 0022 - A rule has a use/exclude polarity

- Date: 2026-11-21
- Status: accepted
- Private history: feature work (no single commit)
- Superseded by: none

## Context

A rule had exactly one state: `enabled`. It could only INCLUDE the directories
it matched in a merge. The player More-menu needs to say "do not use virtual
merge for this video's own folder", which is an exclusion, not a second
inclusion.

## Decision

`VirtualMediaRule` gains `useMode: VmRuleUseMode { use, notUse }`, default
`use`, stored as `vm_rules.use_mode` (schema v54, migration defaults every
existing row to `use`). It is independent of `enabled`:

- `enabled=false` → the rule is ignored entirely;
- `enabled=true, useMode=use` → historical behaviour (merge);
- `enabled=true, useMode=notUse` → exclude the matched files from every merge.

A `notUse` rule never produces a virtual item.

## Consequences

- The folder toggle is one attribute, not a parallel feature.
- Existing installations keep merging because v54 defaults to `use`.
- The editor exposes the same switch, so manual rules can be exclusions.

## Rejected alternatives

- A separate `vm_exclusions` table; it would duplicate the matcher, the editor
  and the settings transfer.
- Encoding exclusion as a `matchMode`; match mode is about HOW a directory is
  selected, not WHAT the selection means.
