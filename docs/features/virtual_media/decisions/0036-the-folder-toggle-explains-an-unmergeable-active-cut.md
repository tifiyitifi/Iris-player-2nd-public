# 0036 - The folder toggle explains an unmergeable active cut

- Date: 2026-11-23
- Status: superseded
- Private history: feature work (no single commit)
- Supersedes: none
- Superseded by: 0037

## Context

The More-menu folder toggle ("使用此文件夹") adopts the file that is already
playing into its merged group and, when it cannot, says "Saved. The current video
keeps playing as a single file; this takes effect on the next play." That promise
is void for one admitted state (ADR 0032): a video whose ACTIVE 虚拟剪播 plan keeps
SEVERAL ranges is always excluded from merges, so no future playback merges it
until the plan changes. The user saw "next play" and waited for a merge that can
never happen.

`VmDirToggleResult` carries no reason for a refused adoption, so the manager
cannot tell "the queue moved on" (waiting helps) from "the cut forbids it"
(waiting cannot).

## Decision

`toggleVmDirUseMode` sets `unmergeableCut` when the folder was switched ON, the
live adoption failed, and the file's ACTIVE cut is the reason it is excluded
(`vmCutBlocksMergeFor`). The manager then shows a dedicated message and the
generic "next play" copy is NOT used.

Message priority stays: failed → master-save failed → paused → unmergeable cut →
generic next-feed.

The check is explicit rather than "adoption failed + has a project": a project
that is closed, single-range, or unusable merges as its source, and those cases
must keep the ordinary copy (waiting does help there only when the queue moved
on; the cut is not the obstacle).

## Consequences

- The user is told the truth on the one state where the folder action cannot
  merge the current video.
- One extra local `.llc` read on a refused adoption — a click, not a hot path.
- The dialog text lives in the ARB files (`vm_dir_result_cut_unmergeable`),
  en + zh.

## Rejected alternatives

- Blame the cut whenever adoption fails: the queue-moved-on case would then lie
  in the other direction.
- Reuse the 虚拟剪播 tab's merge notice (`fake_cut_vm_merged_notice`): that one
  explains the ACTIVE state in the cut tab, which is not where the folder action
  happened, and it does not say the folder rule was saved.
