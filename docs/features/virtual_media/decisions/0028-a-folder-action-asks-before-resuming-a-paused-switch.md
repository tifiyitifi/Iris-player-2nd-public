# 0028 - A folder action asks before it resumes a paused master switch

- Date: 2026-11-22
- Status: accepted
- Private history: feature work (no single commit)
- Superseded by: none

## Context

A real desktop report: "clicked *use Virtual Merge for this folder*, nothing
changed". The database showed why:

- `virtualmedia.masterEnabled` had been `0` for days;
- the folder rule itself had been written and flipped once per click
  (`specifiedDir` on the folder, ending as `notUse`);
- the manager label derives from the DB rule set, so the button text changed
  while `enabledRules()` short-circuited to an empty list, so no list or
  playback could ever change;
- the panel offered no hint and gave no feedback, so the action looked broken.

Two smaller defects in the same panel: the "help" `ExpansionTile` sat inside a
colored `DecoratedBox`, tripping Flutter's debug assertion about invisible ink
splashes, and a rule that could not apply was still written.

## Decision

The folder toggle is now master-switch aware.

- `toggleVmDirUseMode` returns `needsMasterChoice` when the request is "use"
  while the switch is off, and writes NOTHING. The caller asks, then repeats
  the call with a `VmMasterOffChoice`.
- The prompt offers three explicit options: **keep only this folder**
  (`keepOnlyCurrent`), **turn the switch on** (`enableAll`), or **cancel**.
  Dismissing the prompt is a cancel, so the rule set stays byte-identical.
- `keepOnlyCurrent` disables every OTHER enabled rule *before* the switch comes
  back, so resuming never flashes unrelated folders into merged rows. The user
  asked for one folder, not for the whole feature.
- "Not use" stays legal while paused: the exclusion is saved and the result
  says it applies once merging resumes. It never touches the switch.
- The panel shows a persistent "paused" line, and the prompt carries a
  **default-collapsed** explanation below the options (the decision comes
  first; the rationale is opt-in). The disclosure is a local hook state, not an
  `ExpansionTile`, so a reopened dialog can never restore it expanded.
- The management preview keeps resolving rules while paused ("rules are kept"),
  and the new `Material` wrapper gives the help tile its own ink surface.

## Consequences

- Clicking "use" can no longer produce a saved-but-dead rule, and the three
  outcomes are all explainable by the prompt itself.
- Pausing the feature stays a global pause (GATE-3): the switch alone never
  edits rules. `keepOnlyCurrent` DOES disable other rules, but only as an
  explicit, described answer to a user action.
- A user who cancels gets no state change at all, so retrying later is clean.

## Follow-up (same report)

Two defects showed up the moment the fix was used on the real database:

- The prompt was rendered with only TWO tiles when the database held no other
  enabled rule (`otherEnabledCount == 0`). Hiding the folder-only choice made a
  fixed three-way decision look truncated. The tile is now always present and
  only `enabled: false` with an explanatory subtitle — the reader sees the same
  three choices every time, and a disabled tile cannot act.
- The master switch kept showing OFF after the folder action resumed merging.
  It read `VmPrefs.masterEnabled()` in a mount-only effect while the manager
  read the same preference per revision, so the switch and the paused banner
  drifted. `VmMasterSwitch` is now a CONTROLLED widget (`enabled` prop) and the
  manager owns the single read: one value drives both surfaces, so they cannot
  disagree.

Coverage moved to `GATE-6` (fixed three-choice layout),
`GATE-7` (switch follows the resume) and `R26`.

## Rejected alternatives

- Silently turning the switch on inside the command. The pause is deliberate,
  and resuming it can merge unrelated folders the user had parked.
- Only showing a banner and refusing the action. The user's intent ("merge this
  folder") is unambiguous; making them find the switch first is unnecessary
  friction.
- Making `enabledRules()` ignore the switch. That is the meaning of the switch
  (GATE-3) and would resurrect every parked rule.
- Disabling the other rules without asking. Silently editing unrelated rules on
  a "use this folder" click is worse than one extra dialog.
