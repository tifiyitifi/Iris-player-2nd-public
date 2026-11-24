# 0032 - A merge plays the ACTIVE cut, never a bound fallback

- Date: 2026-11-23
- Status: superseded
- Private history: feature work (no single commit)
- Supersedes: 0031
- Superseded by: 0037

## Context

ADR 0031 let a single-range cut join a merge, but chose "the user's active plan,
otherwise the first bound plan". That made the merge disagree with the cut tab:
the tab said "play the source" while merged playback opened a cut the user never
activated, and closing the cut did nothing because the group still fell back to
the bound project. The user asked for the intuitive model: closing the cut must
take effect in the merge, and activating a cut during merged playback must
refresh the merge.

## Decision

A merge follows the SAME cut on/off state the player shows. Per file:

| State | Merge behaviour |
| --- | --- |
| active usable single-range plan + EDL backend | cut segment, duration = kept length |
| active multi-range plan | excluded, keeps its single row |
| active plan unusable/unreadable | SOURCE segment (standalone also plays the source) |
| no active plan | SOURCE segment, duration = source length |
| backend without EDL (fvp) | SOURCE segment (the cut cannot play anywhere) |

There is no fallback to another bound plan. The group carries the chosen
`planPath` and the player opens exactly that plan.

Activating or closing a plan is an ADMISSION change, not just a playback switch:
the cut store calls a late-bound handler that (1) `notifyRulesChanged`s the VM
lists and (2) re-segments the live VM session from fresh groups, BEFORE its
revision bump reopens the media. A live segment whose file left every mergeable
group stops merging and keeps the physical file playing as a single.

## Consequences

- Closing a cut makes the current merged segment play its source and updates the
  merged duration/totals; activating it switches the segment to the cut length.
- The cut tab's selected row now matches what merged playback does.
- A bound-but-inactive `.llc` no longer participates: a merge never plays a cut
  the user has not opened.
- On fvp the file stays mergeable as its source instead of disappearing.
- A plan edit still needs the cut tab's refresh (the project index is explicit).
- The group's `planPath` pins the played EDL, so a racing plan switch cannot
  make the displayed and played durations disagree.

## Rejected alternatives

- Keep the bound-plan fallback and only add refresh signals: closing would still
  not take effect, which is the reported problem.
- Exclude a file whenever it has no active plan: that would silently remove
  ordinary files whose project was authored but not opened, and is not what the
  cut tab shows.
- Reuse the multi-range plan by approximating its length.
