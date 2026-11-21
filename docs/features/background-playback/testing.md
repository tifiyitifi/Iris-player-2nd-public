# Background playback - testing

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

`flutter analyze`. `flutter_lints` is on; `invalid_annotation_target` is ignored.
Custom lint is off.

## 2. Host tests

| Family | Test files |
| --- | --- |
| ENG | `test/bg_engine_*_test.dart`, `test/background_control_target_hit_test.dart` |
| GATE | `test/bg_gate_test.dart`, `test/bg_pair_gate_test.dart`, `test/background_scope_logic_test.dart` |
| POOL | `test/background_queue_logic_test.dart`, `test/bg_queue_window_test.dart`, `test/bg_pool_revision_test.dart` |
| MAP | `test/active_mapping_resolver_test.dart`, `test/mapping_resolver_math_test.dart` |
| APB | `test/segment_span_math_test.dart`, `test/segment_snap_test.dart`, `test/mapping_staging_test.dart` |
| ALIGN | `test/background_alignment_test.dart`, `test/bg_alignment_anchor_test.dart` |
| LOCK | `test/background_sync_logic_test.dart`, `test/bg_mirror_logic_test.dart` |
| VM | `test/bg_vm_align_rule_test.dart`, `test/vm_tiled_bg_plan_test.dart` |
| VOL | `test/background_volume_policy_test.dart`, `test/background_ratio_resolver_test.dart` |
| CUT | `test/fake_cut_background_scope_test.dart` |
| MIG | `test/bg_mapping_segments_migration_test.dart`, `test/v48_bg_source_rules_dropped_test.dart` |
| PLAT | `test/bg_duration_probe_test.dart`, `test/bg_duration_probe_saf_test.dart` |

Single test: `flutter test test/<file>_test.dart`.

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
pwsh -NoProfile -File scripts/check-bg-rules.ps1
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

- Android: SAF single pick (uri identity), local and network storage, both
  backends (`media_kit` and `fvp`).
- Windows: both backends, the blue control frame, the dual-ring dial.
- A real library: a foreground shorter than the background, a background
  shorter with a tail that fits, and a background shorter with a remainder that
  does not fit.
- The eye: the dual-ring handle must agree with the hit area; the readout must
  not jump when an end pins. These are `M` rows (`ring`, `probe`).

## 7. Commit discipline

Red, then Green, then Refactor. A behaviour change starts with a failing test
or a new `rules.md` row that names the test it will turn red. The working branch
stays uncommitted during a session. Committing `docs/**` triggers the existing
`pre-commit` version bump; that is normal.

## 8. Release mirror

The public repository receives `feature/func-squashed-v2` with one squashed
commit per release. Documentation reaches the public mirror only through the
next release squash. `docs/**` is not in `ci.yml`'s `paths-ignore`, so a
docs-only push still runs the full Windows and Android builds.
