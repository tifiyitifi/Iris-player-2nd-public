# Virtual Media - testing

A behaviour change is not finished until the gates agree. They answer different
questions and none replaces another.

| Gate | Question | Cost |
| --- | --- | --- |
| `flutter analyze` | does it type-check under the repo lints | seconds |
| `flutter test` | does every named rule still hold | minutes |
| codegen diff | does generated code match its source | minutes |
| rule register | does every `F:`/`D:` token resolve | seconds |
| privacy gate | does the change leak a local path | seconds |
| device checklist | does it work where the files really are | one run |

## 1. Analysis

```sh
flutter analyze
```

`flutter_lints` is on; `invalid_annotation_target` is ignored. Custom lint is
off.

## 2. Host tests

Eleven families, one per register section. A change to a rule runs its family
and the cross-feature files it touches.

| Family | Test files |
| --- | --- |
| GATE | `test/vm_master_switch_test.dart`, `test/vm_master_off_tag_test.dart`, `test/vm_manager_master_refresh_test.dart`, `test/vm_legacy_sheet_gate_test.dart`, `test/vm_settings_rows_test.dart`, `test/more_menu_vm_entry_test.dart` |
| RULE | `test/vm_resolver_test.dart`, `test/vm_exclusion_rules_test.dart`, `test/vm_naming_test.dart`, `test/vm_folder_defaults_test.dart`, `test/vm_title_composer_test.dart` |
| MERGE | `test/vm_stream_merge_test.dart`, `test/vm_overlay_test.dart`, `test/vm_overlay_children_test.dart`, `test/vm_groups_cache_test.dart`, `test/vm_search_segment_test.dart`, `test/media_search_virtual_page_test.dart` |
| PIN | `test/vm_membership_pin_test.dart`, `test/vm_pin_failed_groups_test.dart`, `test/vm_delete_cascade_test.dart` |
| SESS | `test/vm_session_launcher_test.dart`, `test/vm_playback_plan_test.dart`, `test/vm_playback_session_fixes_test.dart`, `test/vm_reconcile_stale_session_test.dart`, `test/vm_orphan_transition_test.dart`, `test/vm_terminal_dedupe_test.dart`, `test/vm_nav_deactivate_test.dart`, `test/vm_resume_target_test.dart`, `test/vm_resume_occurrence_test.dart`, `test/vm_stop_scope_test.dart`, `test/vm_timeline_ownership_test.dart`, `test/vm_group_position_sync_test.dart` |
| SEEK | `test/vm_step_tail_test.dart`, `test/vm_seek_end_clamp_test.dart`, `test/vm_relative_seek_test.dart`, `test/vm_inner_seek_backtrack_test.dart`, `test/vm_cross_seek_test.dart`, `test/vm_drag_strategy_test.dart` |
| SCAN | `test/vm_preflight_test.dart`, `test/vm_preflight_db_only_test.dart`, `test/vm_duration_scan_test.dart`, `test/vm_duration_backfill_test.dart`, `test/vm_db_durations_saf_test.dart`, `test/vm_scan_facade_test.dart`, `test/vm_pseudo_play_harvest_test.dart`, `test/vm_scan_dialog_test.dart`, `test/vm_scan_dismiss_test.dart` |
| UI | `test/vm_rule_editor_v2_layout_test.dart`, `test/vm_tiled_manual_dialog_test.dart`, `test/vm_mark_color_dialog_test.dart`, `test/vm_scrubber_marks_test.dart`, `test/vm_tick_color_test.dart`, `test/vm_tick_extent_test.dart`, `test/vm_dual_time_test.dart`, `test/vm_dual_time_default_test.dart`, `test/vm_merged_totals_test.dart`, `test/vm_child_segment_list_test.dart`, `test/vm_group_progress_chip_test.dart`, `test/vm_error_dialog_host_test.dart` |
| XFEAT | `test/bg_vm_align_rule_test.dart`, `test/bg_vm_visibility_test.dart`, `test/background_playback_no_virtual_merge_test.dart`, `test/background_scope_panel_vm_test.dart`, `test/vm_fake_cut_exclusion_test.dart`, `test/vm_cut_merge_test.dart`, `test/vm_cut_merge_e2e_test.dart`, `test/vm_cut_plan_edit_test.dart`, `test/vm_cut_plan_notify_test.dart`, `test/vm_cut_range_test.dart`, `test/vm_cut_rescan_refresh_test.dart`, `test/scenario_queue_vm_gate_test.dart`, `test/scenario_vm_tap_matches_display_test.dart`, `test/scenario_vm_group_parity_test.dart`, `test/scenario_vm_total_order_test.dart`, `test/scenario_vm_stream_cache_test.dart`, `test/phone_ring_dial_vm_test.dart`, `test/phone_ring_dial_drag_vm_test.dart`, `test/phone_ring_dial_vm_mapping_test.dart`, `test/phone_ring_dial_vm_lock_test.dart`, `test/ab_loop_virtual_test.dart` |
| MIG | `test/v36_vm_exclusion_columns_test.dart`, `test/v54_vm_rule_use_mode_test.dart`, `test/vm_delete_cascade_test.dart`, `test/vm_transfer_roundtrip_test.dart` |
| DIR | `test/vm_dir_use_mode_test.dart`, `test/vm_resolver_dir_exclusion_test.dart`, `test/vm_dir_toggle_command_test.dart`, `test/vm_dir_toggle_master_off_test.dart`, `test/vm_master_off_dialog_test.dart`, `test/vm_adopt_live_session_test.dart`, `test/vm_dir_toggle_live_adopt_test.dart`, `test/vm_rule_change_queue_refresh_test.dart` |

Single test:

```sh
flutter test test/vm_<family>_test.dart
```

The keyboard shell is a repo-wide contract. The VM editor and the tiled manual
dialog must keep `debugOnFormBuild` at zero on a `viewInsets` change;
`test/keyboard_form_shell_test.dart` is the reference.

## 3. Codegen diff

Any Freezed or Drift change requires:

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
git diff --exit-code -- '*.g.dart' '*.freezed.dart'
```

The last command is the gate: if codegen produced a diff, the generated files
were stale in the change.

## 4. Rule register check

```sh
pwsh -NoProfile -File scripts/check-vm-rules.ps1
```

It parses `rules.md`, resolves every `F:` token against `test/**`, resolves
every `D:` token and every `decisions/` link, and checks that every
`Superseded by:` target exists. Exit code 1 means a row claims coverage it does
not have, or a link points nowhere. It does not read git history, because SHAs
do not survive the public squash.

A row with only `-:<reason>` or `M` is allowed; it is unfalsified, and the
reason says why. Prefer adding the fixture to widening the reason.

## 5. Privacy gate

```sh
pwsh -NoProfile -File scripts/check-local-paths.ps1 -All
```

The local gate rejects drive, UNC and home paths outside the documented
stand-ins, local data files, credentials in URLs, and a real CJK title with an
episode in a prose file. `docs/**` is a prose file. Use stand-ins.

## 6. Device checklist

- Android: SAF single pick, local and network storage, both backends
  (`media_kit` and `fvp`).
- Windows: both backends, the player More entry, the master switch, a physical
  delete inside a merged item.
- A real library: a duplicated file (occurrence), a merged group whose member
  duration is unknown, a network member, and a group that becomes one file after
  `skipSingleSegment`.
- The eye: the scrubber ticks agree with the segment boundaries; the dual time
  rows do not flicker apart; the merged total matches the sum of the segments.
  These are `M` rows.
- 虚拟剪播 interplay: with a merged group playing, activate and close a cut
  (the current segment and the totals follow), edit the active plan on disk
  (the next open of that segment corrects the totals), and rescan the folder
  after adding/removing a `.llc` (the merge row changes without the 虚拟剪播 tab).

`M` steps are named in the register as `M:device checklist#<step>`; the current
steps are `ring` (the phone dial's drawn handle and hit area agree), `ticks`
(the tick colour and extent survive a theme change) and `delete` (a desktop
delete shrinks only its chunk).

## 7. Commit discipline

Red, then Green, then Refactor. A behaviour change starts with a failing test
or a new `rules.md` row that names the test it will turn red. The working branch
stays uncommitted during a session. Committing `docs/**` triggers the existing
`pre-commit` version bump; that is normal.

## 8. Release mirror

The public repository receives one squashed commit per release. Documentation
reaches the public mirror only through the next release squash. SHAs in this
tree are private provenance and are never validated by the checker.
