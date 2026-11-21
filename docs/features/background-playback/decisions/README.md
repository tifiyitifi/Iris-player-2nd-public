# Decisions - background playback

Append-only. A reversed decision keeps its text and gains a `Superseded by`
line. Rule ids and decision numbers are never reused.

| ID | Decision | Status |
| --- | --- | --- |
| [0001](0001-second-independent-engine.md) | Sub Audio runs in a second, independent engine | accepted |
| [0002](0002-candidate-pool-is-the-reserved-tag-view.md) | The candidate pool is the reserved tag view, and it is never VM-merged | accepted |
| [0003](0003-retire-source-rules-and-tag-sources.md) | Retire the source-rule subsystem and the tag scenario sources | accepted |
| [0004](0004-bounded-key-anchored-window.md) | The runtime queue is a bounded, key-anchored window | accepted |
| [0005](0005-store-never-touches-a-player.md) | The store never touches a player | accepted |
| [0006](0006-gate-feature-and-resource-are-separate.md) | Gate, feature switch and resource ownership are separate axes | accepted |
| [0007](0007-follow-the-foreground-only.md) | Sub Audio follows the foreground; it never drives an episode skip | accepted |
| [0008](0008-overlap-resolves-by-activation-order.md) | Overlapping segments resolve by activation order | accepted |
| [0009](0009-position-and-binding-are-decoupled.md) | Position and binding are decoupled | accepted |
| [0010](0010-p-is-a-pure-alignment-handle.md) | P is a pure alignment offset handle | accepted |
| [0011](0011-shuffle-is-local.md) | Shuffle for the Sub Audio pool is local | accepted |
| [0012](0012-anchor-from-the-real-durations.md) | Alignment anchors come from the two real durations | accepted |
| [0013](0013-progress-lock-has-two-axes.md) | Progress lock has two axes | accepted |
| [0014](0014-queue-end-re-activates.md) | A real queue end re-activates; it does not replay | accepted |
| [0015](0015-fake-cut-pauses-under-every-scope.md) | A fake cut pauses Sub Audio under every scope | accepted |
| [0016](0016-migrations-are-reentrant-and-rethrow.md) | Migrations are reentrant and rethrow failures | accepted |
| [0017](0017-completion-and-step-ownership.md) | A completed background master releases the foreground; a user step has one entry | accepted |
| [0018](0018-transport-ownership-and-open-settle.md) | The pair's transport has one owner, and a real command always lands | accepted |
| [0019](0019-probe-writeback-and-superseded-opens.md) | A probe write-back reaches the timeline; a refusal supersedes | accepted |
| [0020](0020-editor-draws-the-file-it-names.md) | The editor draws and measures the media it actually names | accepted |
| [0021](0021-switch-direction-and-refresh-anchor.md) | A switch keeps its direction, a refresh keeps its track | accepted |
