# 0024 - The More-menu folder toggle is non-recursive and cheap

- Date: 2026-11-21
- Status: accepted
- Private history: feature work (no single commit)
- Superseded by: none

## Context

The player More-menu opens `VmManagerPage`. It must show the video that was
playing when it opened and a single flip-labelled button for that video's
DIRECT folder. The machine can hold 50 万 media items, so the feature must not
regress the default merge pipeline.

## Decision

The panel freezes the current `FileItem` at open (name only). The button:

- no covering rule → create a `specifiedDir` rule from the default config and
  enable it (`use` when nothing merges the file, `notUse` when only a
  recursive rule covers it, so only this folder is carved out);
- an existing `specifiedDir` rule for the path → toggle ITS polarity and keep
  it enabled (never create a duplicate);
- when the live session's own folder is switched to `notUse` → deactivate the
  session immediately and keep the current physical file playing (single).

Performance: the resolver computes `vmEffectiveUseMask` only when at least one
ENABLED `notUse` rule exists. Otherwise it returns null and the 500k pipeline
pays one boolean test (the historical cost). When a mask is needed it is a
`Uint8List` (one byte per file, ~0.5 MB at 500k), built in ONE pass with
tier short-circuiting — never a `Set<String>` of every file. The management
preview is capped at 50k and may materialize a set.

Polarity changes clear the rule's `vm_progress` and anchors in the same
transaction (`setRuleUseMode`), because the scope semantics changed.

## Consequences

- Default users see no performance change.
- A folder switch is one rule write, not a rescan.
- The conflict dialog is the single fence for "which stays enabled".

## Rejected alternatives

- Recomputing exclusions per rule (doubles the 500k match cost).
- A 500k `Set<String>` mask (tens of MB on a low-end phone).
- Leaving the old session running after its folder is excluded (it would keep
  advancing through a merge the user just turned off).
