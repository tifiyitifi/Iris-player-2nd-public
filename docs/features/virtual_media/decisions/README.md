# Decisions - Virtual Media

Append-only. A reversed decision keeps its text and gains a `Superseded by`
line. Rule ids and decision numbers are never reused.

| ID | Decision | Status |
| --- | --- | --- |
| [0001](0001-rules-are-data-without-priority.md) | Rules are data and have no priority | accepted |
| [0002](0002-the-displayed-group-is-the-playback-group.md) | The displayed group is the playback group | accepted |
| [0003](0003-number-merged-items-by-queue-position.md) | Number merged items by queue position | superseded by 0004 |
| [0004](0004-keep-the-title-number-distinct-from-the-row-position.md) | Keep the title number distinct from the row position | accepted |
| [0005](0005-hard-caps-32-and-300.md) | Chunk caps have hard ceilings | accepted |
| [0006](0006-unknown-duration-joins-and-degrades.md) | An unknown duration joins and degrades | accepted |
| [0007](0007-sequential-opens-not-a-virtual-timeline.md) | Playback is sequential opens, not a virtual timeline | accepted |
| [0008](0008-resume-by-file-recency.md) | Resume by file recency | accepted |
| [0009](0009-tail-finish-is-a-hook-not-a-seek.md) | A tail finish is a hook, not a seek | accepted |
| [0010](0010-pin-freezes-boundaries-only.md) | The pin freezes boundaries, not membership | accepted |
| [0011](0011-master-switch-pauses-instead-of-rewriting.md) | The master switch pauses, it does not rewrite | accepted |
| [0012](0012-gate-makes-the-feature-absent.md) | The gate makes the feature absent | accepted |
| [0013](0013-one-write-back-seam-for-duration-acquisition.md) | Duration acquisition has one write-back seam | accepted |
| [0014](0014-sub-audio-bridge-stays-on-the-vm-side.md) | The Sub Audio bridge stays on the VM side | accepted |
| [0015](0015-fake-cut-excludes-by-sibling-project-file.md) | A fake cut excludes by sibling project file | superseded by 0031 |
| [0016](0016-derived-index-revision-follows-duration-heal.md) | The derived revision follows a duration heal | accepted |
| [0017](0017-legacy-sheet-sealed-and-default-rule-seeded-once.md) | The legacy sheet is sealed and the default rule is seeded once | accepted |
| [0018](0018-first-feed-failure-is-recoverable.md) | A failed first feed is recoverable | accepted |
| [0019](0019-terminal-events-are-serialized-by-the-transition.md) | Terminal events are serialized by the transition | accepted |
| [0020](0020-a-valid-group-owns-its-file.md) | A valid group owns its file | accepted |
| [0021](0021-saf-identity-uses-the-uri-key.md) | SAF identity uses the uri key | accepted |
| [0022](0022-a-rule-has-a-use-exclude-polarity.md) | A rule has a use/exclude polarity | accepted |
| [0023](0023-non-recursive-wins-and-one-enabled-rule-per-folder.md) | Non-recursive wins, and one enabled rule per folder | accepted |
| [0024](0024-more-menu-folder-toggle-is-non-recursive-and-cheap.md) | The More-menu folder toggle is non-recursive and cheap | accepted |
| [0025](0025-a-rule-change-adopts-the-live-feed.md) | A rule change adopts the live feed instead of waiting for the next file | accepted |
| [0026](0026-folder-rule-identity-follows-the-filesystem.md) | Folder rule identity follows the filesystem | accepted |
| [0027](0027-a-rule-change-refreshes-open-surfaces.md) | A rule change refreshes the surfaces that are already open | accepted |
| [0028](0028-a-folder-action-asks-before-resuming-a-paused-switch.md) | A folder action asks before it resumes a paused master switch | accepted |
| [0029](0029-a-failed-vm-write-changes-nothing.md) | A failed VM write changes nothing and is reported | accepted |
| [0030](0030-one-notification-per-folder-action.md) | One notification fan-out per folder action | accepted |
| [0031](0031-a-single-range-cut-may-join-a-merge.md) | A single-range cut may join a merge | superseded by 0032 |
| [0032](0032-a-merge-plays-the-active-cut-only.md) | A merge plays the active cut, never a bound fallback | superseded by 0037 |
| [0033](0033-a-rescan-refreshes-the-cut-project-index.md) | A media rescan refreshes the cut-project index | accepted |
| [0034](0034-an-edited-plan-re-derives-the-live-merge.md) | An edited cut plan re-derives the live merge | accepted |
| [0035](0035-a-cut-plan-change-re-groups-without-clearing-scan-bookkeeping.md) | A cut-plan change re-groups without clearing scan bookkeeping | accepted |
| [0036](0036-the-folder-toggle-explains-an-unmergeable-active-cut.md) | The folder toggle explains an unmergeable active cut | superseded by 0037 |
| [0037](0037-every-kept-range-of-the-active-cut-merges.md) | Every kept range of the active cut merges | accepted |
| [0038](0038-a-plan-edit-re-derives-after-the-in-flight-feed.md) | A plan edit re-derives after the in-flight feed settles | accepted |
