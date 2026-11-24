# Virtual Cut - testing

## Gates

| Gate | Command | Question |
| --- | --- | --- |
| analysis | `dart analyze lib/features/fake_cut lib/hooks/player/use_media_kit_player.dart` | does it type-check |
| host tests | `flutter test test/fake_cut_*_test.dart` | does every named rule still hold |
| full suite | `flutter test` | did a neighbour break (merge, 副音, player hooks) |
| rule register | `pwsh -NoProfile -File scripts/check-fake-cut-rules.ps1` | does every `F:`/`D:` token resolve |
| VM register | `pwsh -NoProfile -File scripts/check-vm-rules.ps1` | did the merge side of the contract move |
| privacy gate | the repo pre-commit hook | no real path/title/account in the change |
| device | the checklist below | does an actual EDL play on both hosts |

The rule checker is ASCII-only and self-testing:

```sh
pwsh -NoProfile -File scripts/check-fake-cut-rules.ps1 -SelfTest
pwsh -NoProfile -File scripts/check-fake-cut-rules.ps1
```

## Test families

| Family | Files |
| --- | --- |
| Project I/O | `test/fake_cut_llc_parser_test.dart`, `test/fake_cut_json5_test.dart`, `test/fake_cut_io_test.dart`, `test/fake_cut_project_index_test.dart`, `test/fake_cut_pairing_test.dart` |
| Plan & timeline | `test/fake_cut_plan_builder_test.dart`, `test/fake_cut_timeline_test.dart`, `test/fake_cut_resume_test.dart`, `test/fake_cut_edl_builder_test.dart` |
| Store & open | `test/fake_cut_store_test.dart`, `test/fake_cut_open_session_test.dart`, `test/fake_cut_preflight_test.dart` |
| Coexistence | `test/fake_cut_background_scope_test.dart`, `test/fake_cut_subtitle_remapper_test.dart`, `test/fake_cut_texts_test.dart`, `test/vm_cut_merge_test.dart`, `test/vm_cut_merge_e2e_test.dart` |

Fixtures write real temp directories; each suite tears its directory down. No
test drives media_kit's native decoder, so the last mile (`player.open` on an
EDL) stays a device step.

## Device checklist

- Windows + media_kit: author a `.llc` in LosslessCut, refresh or rescan, open
  the video, activate the plan, seek across a removed gap, close it again.
- Android + media_kit: the same with a local file; confirm the EDL opens from the
  app cache and the scrubber follows the cut timeline.
- fvp: standalone 虚拟剪播 is blocked with the localized explanation; the same
  file inside a merge plays its source.
- 副音: start a cut, confirm the other video keeps its sound, and that leaving
  the cut restores it.
- Subtitles: an external SRT/ASS is re-timed to the kept ranges.
- Merge: activate/close a cut during a merged group; the current segment and the
  merged total follow (see `../virtual_media/testing.md`).

`M:device checklist#edl` is named by `FC-08`.
