# Background playback - rule register

The normative cases. `spec.md` owns the requirement; this file owns the case
that holds it. `design.md` holds the mechanism behind a rule.

Columns:

- **Case** - the situation, in one line.
- **Evidence** - what the row has to show for the behaviour to be allowed.
- **Behaviour** - what the feature must do. Normative.
- **Why** - the private-history commit that made this a rule, then the reason.
- **Coverage** - `;`-separated tokens in one cell:
  - `F:<file>#<test name>` - a literal test in `test/<file>.dart`; it must fail
    when the rule breaks. `scripts/check-bg-rules.ps1` resolves every token.
  - `F:<file>` - a file-level fallback for parameterised or generated tests.
  - `D:<nnnn>` - the governing decision record.
  - `M:<step>` - a human device check named in `testing.md`.
  - `-:<reason>` - deliberately not held by an executable test.

A rule that stops being true is **superseded**, not deleted: keep the row, mark
it and leave the coverage that used to hold it.

## ENG - engine and control target

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| ENG-1 | Two engines | The engine has no VM, history or progress writer | WHEN a background file plays, THE SYSTEM SHALL use a separate engine that does not share foreground transport or progress | `8bf05042` a second track must not touch the first player | `F:bg_engine_stop_unload_test`; `F:bg_engine_empty_uri_test` |
| ENG-2 | Control retargeting | The blue frame sits on the control bar only | WHEN the target is the background, THE SYSTEM SHALL route the shared controls and mark the control bar | `7040f726` one control bar, two engines | `F:background_control_target_hit_test`; `F:background_target_frame_transform_test` |
| ENG-3 | Stale open guard | A slow open may finish after a newer one | WHEN a newer file is opened (or a refusal unloads the runtime), THE SYSTEM SHALL ignore the earlier open | `eccaee0a` a late open must not steal the current file | `F:bg_fvp_open_generation_test`; `F:bg_fvp_open_generation_test#an empty-uri refusal supersedes an open still in flight` |
| ENG-4 | Resolved durations reach the timeline | The queue-duration read the virtual axis is built from | WHEN a probe pass resolves a queue entry's duration, THE SYSTEM SHALL re-read the queue durations so the timeline (and its prefix/roll math) sees them without a queue rebuild | `f37fc28c` a write-back was invisible for the whole session | `F:bg_continuation_resume_test#a probe write-back re-keys the playback timeline`; `D:0019` |

## GATE - gate, scope and ownership

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| GATE-1 | Pure stop | Stop must not rewrite the run | WHEN the user stops, THE SYSTEM SHALL pause in place and keep run, queue, index and opt-outs | `2b8c2f63` stop is not reset | `F:bg_gate_test#stopGate is a pure stop: run, queue, index and opt-outs survive` |
| GATE-2 | Armed is not playing | Cold load arms with the gate shut | WHEN a run is armed, THE SYSTEM SHALL not start transport until the gate opens | `2b8c2f63` the gate is the permission, not the power | `F:bg_gate_test#armRunStopped arms the run without playing and leaves the gate shut` |
| GATE-3 | Scope transitions | Scope decides pause/resume | WHEN the foreground leaves the anchored media under currentOnly, THE SYSTEM SHALL pause, and resume on return | `bc0f3504` scope, not a boolean | `F:background_scope_logic_test#currentOnly pauses when leaving the anchored media`; `F:background_scope_logic_test#currentOnly resumes when returning to the anchored media` |
| GATE-4 | Pair ownership | Ownership is a derived state | WHEN the pair is armed, in gate and in scope, THE SYSTEM SHALL own controls and picture; otherwise hand them back | `9eadfde9` ownership follows the pair | `F:bg_pair_gate_test#an armed, in-gate, in-scope run owns both`; `F:bg_pair_gate_test#a forward step at the end latches it and hands back the pair` |
| GATE-5 | Collision is not queue end | A double-play guard is not exhaustion | WHEN every remaining candidate collides with the foreground, THE SYSTEM SHALL not treat it as the end of the queue — a non-looping step SHALL skip the colliding entry and take the following one | `a2b088b7` a collision is not an end | `F:bg_pair_gate_test#a double-play collision is NOT the end of the queue`; `F:background_playback_store_test#a repeat-none step skips a colliding neighbour instead of stalling`; `D:0014`; `D:0019` |
| GATE-6 | Apply to current | Apply re-anchors the media | WHEN apply-to-current runs, THE SYSTEM SHALL re-anchor and respect keepQueueProgress | `e4103219` apply is a per-media activation | `F:bg_apply_to_current_test#media switch away then apply re-anchors and resumes`; `F:bg_apply_to_current_test#keepQueueProgress never lands on the foreground file` |
| GATE-7 | Keyboard gate | One shortcut toggles the gate | WHEN the gate shortcut is pressed for the current video, THE SYSTEM SHALL open it, and a second press SHALL stop and hand back | `a93e4eac` Alt+' is the gate | `F:background_gate_activation_transport_test` |
| GATE-8 | One step entry | Every control surface that steps the pair | WHEN the user steps from any control surface while the background owns the controls, THE SYSTEM SHALL route through the background router with the foreground double-play guard and the manual-switch mark | `5ef14f87` a direct store call dropped both guards | `F:bg_control_bar_step_routing_test#the control-bar next button routes a bg step through the router`; `D:0017` |
| GATE-9 | One transport flag | Every surface that toggles the pair's play state | WHEN a surface toggles play/pause while the background owns the controls, THE SYSTEM SHALL publish `bgAutoPlay` and SHALL NOT write the foreground autoplay preference | `add91d48` four surfaces still wrote the foreground flag | `F:bg_transport_flag_ownership_test#the default keyboard scheme pauses 副音 through its own flag`; `F:bg_transport_flag_ownership_test#the ring-dial centre tap pauses 副音 through its own flag`; `D:0018` |
| GATE-10 | An open drops no command | Transport commands issued while a file is opening | WHEN a play/pause command is issued while the background file is still initializing, THE SYSTEM SHALL apply it once the open settles | `add91d48` a stop during a slow open still started the track | `F:bg_open_transport_settle_test#a stop issued while the file opens still stops it`; `F:bg_open_transport_settle_test#a play issued while the file opens actually starts it`; `D:0018` |
| GATE-11 | A row tap re-activates | The stopRestoreFg terminal run | WHEN the user picks a queue row while the run is parked as exhausted, THE SYSTEM SHALL clear the terminal latch so the duck gate, the mirrors and the controls all see a live pair again | `e24d1fd7` a row tap sounded muted until an alignment happened to land | `F:background_playback_store_test#a row tap re-activates a run that stopped for good`; `D:0021` |

## POOL - candidate pool and queue

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| POOL-1 | Reserved tag only | The pool is the tag view | WHEN the pool resolves, THE SYSTEM SHALL read the reserved tag membership and its ordering | `82784a89` one source, the tag view | `F:background_scenario_source_test#the candidate stream is the reserved tag membership`; `F:background_scenario_source_test#the tag view ordering drives the candidate stream` |
| POOL-2 | Local shuffle | Shuffle must not reorder the shared view | WHEN shuffle is on, THE SYSTEM SHALL permute locally by seed and renumber virtualIndex | `82784a89` shuffle is a view, not a write | `F:bg_shuffle_order_test#renumbering after the shuffle keeps virtualIndex == position`; `F:bg_shuffle_order_test#seed 0 leaves the order untouched` |
| POOL-3 | Bounded window | The stream is resolved page by page | WHEN a global jump lands outside the window, THE SYSTEM SHALL slide onto the page that contains it | `7fbb0904` a huge list is resolved per page | `F:bg_queue_window_test#the pool resolves a window, not the whole list`; `F:bg_queue_window_test#a jump far outside the window slides onto it` |
| POOL-4 | Global index | A row index is a global position | WHEN a row is tapped, THE SYSTEM SHALL play the file the view shows at that global position | `c8ee84fa` page rows are not queue indices | `F:bg_queue_window_test#resolveCurrentItemIndex is a GLOBAL position, not a page row` |
| POOL-5 | Double-play guard | The foreground file stays a member | WHEN the start index is chosen, THE SYSTEM SHALL skip the foreground media unless allowSameFgBgFile is on | `ca09b4fb` the foreground may be tagged too | `F:bg_start_index_test#enableWithQueue skips a leading foreground entry`; `F:bg_start_index_test#the guard lifts entirely with allowSameFgBgFile` |
| POOL-6 | Coalesced revision | A tag import writes rows one by one | WHEN relevant membership writes arrive in a burst, THE SYSTEM SHALL coalesce them into one signal | `32feeca1` one import is one change | `F:bg_pool_revision_test#a burst of writes is coalesced into a single bump`; `F:bg_pool_revision_test#a relevant membership write bumps the revision` |
| POOL-7 | Queue reconcile | A live queue follows membership | WHEN the pool gains a member, THE SYSTEM SHALL rebuild or append without reordering a shuffled queue | `32feeca1` a new tag reaches the running queue | `F:bg_tag_sync_logic_test#rebuild replaces the queue when the pool gained a member`; `F:bg_tag_sync_logic_test#a shuffled queue ignores pool order` |
| POOL-8 | Refresh keeps the playing file | 「立即更新」 on a running pair | WHEN the candidate pool is refreshed while 副音 runs, THE SYSTEM SHALL resolve the new page around the file that is playing, never around the remembered occurrence | `e24d1fd7` a page without the current track paused the pair | `-:no seam without a >400 pool`; `D:0021` |

## MAP - mapping timeline

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| MAP-1 | Last activated wins | Overlap is allowed | WHEN two segments overlap, THE SYSTEM SHALL play the one with the highest activeSeq | `d0c91e6c` last fired wins | `F:active_mapping_resolver_test#the later-activated segment wins the overlap`; `D:0008` |
| MAP-2 | Disabled is invisible | Disabled rows must not reach the axis | WHEN a segment is disabled, THE SYSTEM SHALL hide it from resolution and from the overview | `d0c91e6c` a disabled segment is off | `F:active_mapping_resolver_test#a disabled segment is invisible` |
| MAP-3 | Half-open ranges | Boundaries are half-open | WHEN a position sits exactly on a boundary, THE SYSTEM SHALL resolve it with half-open semantics | `d0c91e6c` no double coverage | `F:active_mapping_resolver_test#range is half-open at both ends`; `F:mapping_resolver_math_test#segmentAt resolves the covering window (half-open), else gap` |
| MAP-4 | Overlap clip modes | keepFront/keepBack/overwrite | WHEN a new segment overlaps, THE SYSTEM SHALL apply the chosen clip mode and emit residual gaps | `a518fc43` the editor must not lose the old span | `F:mapping_resolver_math_test#keepFront clips the new segment before the existing one`; `F:mapping_overlap_split_test#middle overlap yields a left and a right residual` |
| MAP-5 | Validation | A playMedia needs a file; silence must not carry one | WHEN a timeline is saved, THE SYSTEM SHALL reject playMedia without a background file and silence with one | `a93b1fa4` a segment must say what it binds | `F:background_mapping_repository_test#playMedia without a bg file is rejected`; `F:background_mapping_repository_test#overlapping fg ranges are allowed and persist activation fields` |

## APB - A/P/B editor

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| APB-1 | P is offset only | P changes alignment, not the span | WHEN P moves, THE SYSTEM SHALL change the offset and leave A/B alone when room exists | `230b77a7` P is a cursor, not a window | `F:segment_span_math_test#changes the offset and leaves A/B alone when room exists`; `D:0010` |
| APB-2 | Binding decoupled | Swapping the file keeps A/B and P | WHEN the background file is replaced, THE SYSTEM SHALL keep the A/B span and the offset | `a518fc43` a swap is not a re-clamp | `F:mapping_staging_test#swaps the bg of the targeted segment only, keeping its span`; `D:0009` |
| APB-3 | Snap walls | Saved edges are snap walls with a release history | WHEN a drag crosses a saved edge, THE SYSTEM SHALL stop, and SHALL release it for the rest of the gesture | `f2dd0787` snap to saved edges, not to a grid | `F:segment_snap_test#moving up stops at the first crossed wall`; `F:segment_snap_test#released walls are passable, the next live wall still blocks` |
| APB-4 | Transport frozen | The editor owns transport | WHEN the editor opens, THE SYSTEM SHALL freeze and pause the pair, and restore transport on exit | `18a853d1` editing and playing must not race | `F:segment_edit_guard_test#exiting the editor restores transport`; `F:segment_edit_guard_test#disable() clears the editor session` |
| APB-5 | Entry target | The editor opens on the in-use segment | WHEN no segment is under the playhead, THE SYSTEM SHALL open the nearest active segment | `933a9dd3` open where the user was | `F:segment_entry_target_test#picks the nearest interval, before or after the playhead`; `F:segment_abp_test#opens ON the in-use saved segment (id + order + full values)` |
| APB-6 | Staged apply | Manager drafts are staged per foreground | WHEN the committed row changed since the baseline, THE SYSTEM SHALL refuse the apply | `d1d1f3e4` staged edits must not overwrite a newer save | `F:mapping_staging_test#refuses when the committed row changed since the baseline` |
| APB-7 | PlayMedia is 1:1 | A playMedia draft is a strict window | WHEN a playMedia draft is saved, THE SYSTEM SHALL persist a strict 1:1 window | `a7f6f038` a playMedia binds one window | `F:segment_edit_draft_test#playMedia persists a strict 1:1 window` |
| APB-8 | Ring feel | The drawn handle and the hit area must agree | WHEN the dual-ring handle is dragged, THE SYSTEM SHALL keep the drawn handle and the hit area together | `e8c330e2` the handle must not become a dead spot | `M:device checklist#ring`; `-:feel needs a device` |
| APB-9 | Timeline geometry | Track centres and section height describe the real column | WHEN the linear editor draws the fg↔bg link and the A/B edge rules, THE SYSTEM SHALL place them on the actual two-row column (fg, gap, bg) with no unused strip | `84c5c072` the constants budgeted a bg name row the layout never emits, drawing the connector 22px low | `F:segment_timeline_geometry_test#the timeline column is exactly two track rows and the gap`; `D:0020` |
| APB-10 | An empty bg row is inert | The bg scrub row with no 副音 file loaded | WHEN the bg duration is unknown, THE SYSTEM SHALL NOT turn a touch on the bg row into a foreground seek | `84c5c072` a live slider over an empty track dragged the video playhead | `F:segment_bg_row_inert_test#an empty bg row has no seek target`; `D:0020` |
| APB-11 | Measure the draft's own file | The bg total a saved row records | WHEN a segment is saved, THE SYSTEM SHALL record the duration of the 副音 file the DRAFT names, never the engine's currently loaded file | `84c5c072` a foreign duration normalized the wrong covered region | `F:segment_edit_save_bg_total_test#a foreign bg file is measured by its OWN duration`; `F:segment_edit_save_bg_total_test#an unresolvable foreign bg records NO total instead of a foreign one`; `D:0020` |

## ALIGN - alignment

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| ALIGN-1 | Auto anchor | Two real durations decide | WHEN the background first opens, THE SYSTEM SHALL anchor from the two real durations and not persist a default mode | `2a17137e` anchor from the files, not a setting | `F:bg_alignment_anchor_test#same-clock mode maps both origins (offset 0)`; `D:0012` |
| ALIGN-2 | Explain, don't offer | The note is read-only; the manual tab stays | WHEN the automatic rule is shown, THE SYSTEM SHALL explain it and keep the manual re-align tab | `456d9b34` the rule is not a menu | `F:bg_alignment_anchor_test#a legacy ask keeps the new default (sameClock)`; `D:0012` |
| ALIGN-3 | Tail threshold | A warning can pause | WHEN the mapped remainder drops below the threshold, THE SYSTEM SHALL warn; the threshold cannot be off | `2a17137e` never silently run out | `F:background_alignment_test#floors at 1s and caps at 120s (cannot be off)` |
| ALIGN-4 | Continuation | A cross-file continuation keeps the pin | WHEN the queue continues into the next file, THE SYSTEM SHALL keep the pinned offset | `838c15f9` a stale pin drifts | `F:bg_continuation_test#non-zero offset is preserved across the boundary`; `F:bg_continuation_resume_test#the pin IS derived once the prefix through the anchor is known` |
| ALIGN-5 | Lock timeline | Prefix sums map a virtual position | WHEN the queue axis is mapped, THE SYSTEM SHALL use prefix sums and wrap or clamp by the repeat mode | `a8dc6d30` one virtual timeline over the queue | `F:background_lock_mapping_test#prefix sums and offsets`; `F:background_lock_mapping_test#a +10s/-10s skip shifts by the same amount` |

## LOCK - progress lock and sync

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| LOCK-1 | Two axes | Link and level are separate | WHEN the lock is independent, THE SYSTEM SHALL share neither transport nor seek; low keeps play/pause | `a8dc6d30` one boolean could not express it | `F:bg_lock_split_test#independent silences both transport and seek`; `F:bg_lock_split_test#low keeps play/pause but frees seeks`; `D:0013` |
| LOCK-2 | Seek only high | Seeks mirror only on linked + high | WHEN the level is low, THE SYSTEM SHALL not mirror a seek | `783c388b` high sync is the full mirror | `F:background_sync_logic_test#only linked + high mirrors seeks`; `F:bg_lock_split_test#high mirrors both` |
| LOCK-3 | No ping-pong | Our own landing must be swallowed | WHEN the mirror lands, THE SYSTEM SHALL swallow that sample and never mirror it back | `34a96c68` the loop must settle | `F:bg_mirror_logic_test#the ping-pong settles: bg landing -> fg seek -> fg landing -> anchor`; `F:bg_mirror_logic_test#our own bg landing is swallowed, never mirrored to the fg`; `D:0007` |
| LOCK-4 | Never rewind | Drift correction is forward-only | WHEN a drift correction runs, THE SYSTEM SHALL never rewind the video | `34a96c68` correction is not a rewind | `F:bg_continuous_sync_test#a drift correction must never rewind the video`; `F:bg_continuous_sync_test#bg master pulls the foreground once the drift exceeds tolerance` |
| LOCK-5 | Scrub | A scrub drag suppresses the jump mirror | WHEN a scrub drag is in flight, THE SYSTEM SHALL suppress the foreground-jump mirror and re-align on release | `5859b03e` the drag owns the position | `F:bg_scrub_interplay_test#a scrub drag suppresses the fg-jump mirror (no bg dragging)`; `F:bg_scrub_interplay_test#linked + high follows the drag AND must land aligned` |
| LOCK-6 | Seek window | A/B bounds publish a playable window | WHEN current-only and high are active, THE SYSTEM SHALL publish the A/B seek window | `783c388b` the slider must not leave the segment | `F:bg_seek_window_test#a strict subset has a limit and reports both fractions`; `F:bg_seek_window_test#out-of-range bounds are clamped into the file` |
| LOCK-7 | Ended master is not a pause | The background engine parked on its natural end | WHEN the background master reaches its natural end, THE SYSTEM SHALL NOT mirror the ended pause onto the foreground transport; the completion continuation owns the pair until playback is decided again (play, pause, seek, stop or a new open) | `5ef14f87` a completed master froze the video | `F:bg_continuation_resume_test#a bg-master completion does not pause the foreground`; `F:bg_continuation_resume_test#a pause during the completion hold releases the mirror`; `F:bg_engine_completion_latch_test`; `D:0017`; `D:0018` |

## VM - Virtual Media boundary

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| VM-1 | No merge | The pool never VM-merges | WHEN the pool resolves, THE SYSTEM SHALL NOT apply virtual-merge rules | `6afffc08` the members vanished under the VM rules | `F:background_playback_no_virtual_merge_test#background_playback never applies virtual-merge rules`; `D:0002` |
| VM-2 | Item vs segment switch | Two independent actions | WHEN the list item changes, THE SYSTEM SHALL apply the item switch; when the VM segment changes, the segment switch | `2eadac12` a new file and a new segment are different | `F:bg_vm_align_rule_test#cross-video switches: item defaults newBg, segment keepPlaying` |
| VM-3 | Scope identity | perBlock vs wholeVirtual | WHEN the VM scope mode is wholeVirtual, THE SYSTEM SHALL publish the virtual identity; perBlock keeps the physical block | `6cfd937b` identity decides the mapping key | `F:bg_vm_align_rule_test#perBlock keeps the physical block identity (default)`; `F:bg_vm_align_rule_test#wholeVirtual publishes the virtual video identity` |
| VM-4 | Tiled plan | One-shot tiling over VM segments | WHEN a VM segment starts mid-file, THE SYSTEM SHALL keep the inner offset in the tiled plan | `ac990876` one queue over many segments | `F:vm_tiled_bg_plan_test#a segment starting mid-file keeps the inner offset`; `F:vm_tiled_bg_plan_test#an unusable bg timeline degrades to all-null (keep playing)` |
| VM-5 | Session-only overrides | Tiled overrides never persist | THE SYSTEM SHALL keep tiled overrides session-only | `783c388b` a rebuild must not resurrect a stale slot | `F:vm_tiled_override_test#overrides are session-only: never persisted, never restored` |
| VM-6 | Background hides VM chrome | The background target has no VM item | WHEN the target is the background, THE SYSTEM SHALL suppress the VM item and the scrubber marks | `dcbb3f2b` the second track is one file | `F:bg_vm_visibility_test#suppresses the VM item for the background target`; `F:bg_vm_visibility_test#bg target empties the scrubber marks (single-file track)` |
| VM-7 | Item switch direction | An item switch steps the pair the same way | WHEN the VM item changes, THE SYSTEM SHALL step 副音 in the direction the foreground moved (queue stamp first, VM queue index as the fallback) | `e24d1fd7` 「上一集」 pushed 副音 forward | `F:vm_bg_step_direction_test#the queue move stamp wins over the VM queue indices`; `F:vm_bg_step_direction_test#without a stamp a lower VM queue index steps backward`; `D:0021` |

## VOL - volume

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| VOL-1 | Duck gate | Active means enabled, gate open, not exhausted | WHEN the pair is not active, THE SYSTEM SHALL pass the master through to the foreground unchanged | `243b7376` duck only when the pair really runs | `F:background_volume_policy_test#only enabled AND gate open AND not exhausted is active`; `F:background_volume_policy_test#bg on scales the foreground by the fg ratio (default 30%)` |
| VOL-2 | Independent mutes | Each track mutes alone | WHEN the background mute is on, THE SYSTEM SHALL silence only the background track | `243b7376` two tracks, two mutes | `F:background_volume_policy_test#quick mute via bgPercent=0 silences the background engine`; `F:background_ratio_resolver_test#clamps out-of-range stored values into 0..100` |

## CUT - fake cut

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| CUT-1 | Pause under every scope | A cut pauses Sub Audio for that media | WHEN a fake cut owns the media, THE SYSTEM SHALL pause Sub Audio under every scope | `993cc06c` the cut and the second track share a timeline | `F:fake_cut_background_scope_test#only the file whose open adopted the cut stands down`; `D:0015` |
| CUT-2 | Resume only if sounding | A paused run is not resurrected | WHEN the cut ends, THE SYSTEM SHALL resume only a run that was sounding | `993cc06c` a user pause is not a cut pause | `F:background_playback_store_test#a user-paused run is not resurrected when the cut ends`; `F:background_playback_store_test#two cuts in a row keep the resume memory` |

## MIG - migrations

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| MIG-1 | Reentrant | Migrations must survive a re-run | WHEN a migration re-runs, THE SYSTEM SHALL leave a usable timeline and add columns only when missing | `ed42c848` a stamped-past database still needs the fix | `F:bg_mapping_segments_migration_test#is re-entrant and leaves a populated timeline usable`; `F:bg_mapping_segments_v34_migration_test#is re-entrant`; `D:0016` |
| MIG-2 | Backfill | v34 backfills active_seq | WHEN v34 runs, THE SYSTEM SHALL backfill active_seq from the row id | `d0c91e6c` old rows need an order | `F:bg_mapping_segments_v34_migration_test#adds the columns and backfills active_seq from the row id` |
| MIG-3 | Drop is reentrant | v48/v49 drop legacy objects | WHEN v48 or v49 runs, THE SYSTEM SHALL drop the legacy objects re-entrantly | `d716706a` a failed DROP was swallowed | `F:v48_bg_source_rules_dropped_test#MigrationV48 drops a legacy table, re-entrantly`; `F:v48_bg_source_rules_dropped_test#MigrationV49 deletes tag sources and drops tag_id, re-entrantly` |
| MIG-4 | Index idempotent | v35 index creation | WHEN v35 runs twice, THE SYSTEM SHALL keep the indexes | `ed42c848` a re-run must not fail | `F:migration_v35_indexes_test#v35 migration is idempotent (re-running keeps the indexes)` |

## PLAT - platform and identity

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| PLAT-1 | Probe never fabricates | Unknown stays unknown | WHEN a probe fails or returns zero, THE SYSTEM SHALL not fabricate a duration | `74fd28ba` a guessed duration corrupts the mapping | `F:bg_duration_probe_test#a non-positive probe duration is a failure`; `F:bg_duration_probe_test#a write-back with no matching DB row is a FAILURE, not a success` |
| PLAT-2 | SAF identity | A single pick is identified by uri | WHEN a row has an empty path, THE SYSTEM SHALL match it through its document uri | `0eb10527` a SAF pick has no path | `F:bg_duration_probe_saf_test#two single picks keep SEPARATE rows and each writes its OWN duration` |
| PLAT-3 | Three-level resolver | Mapped over engine over natural | WHEN the mapped segment drives Sub Audio, THE SYSTEM SHALL prefer it over the engine and the natural queue | `dcbb3f2b` one answer to "what is playing" | `F:current_bg_resolver_test#the mapped segment file outranks the engine and the natural queue` |
| PLAT-4 | Probe UI | The probe dialog shows progress | WHEN a probe runs, THE SYSTEM SHALL show progress without blocking playback | `74fd28ba` probing is background work | `-:visual timing only`; `M:device checklist#probe` |
