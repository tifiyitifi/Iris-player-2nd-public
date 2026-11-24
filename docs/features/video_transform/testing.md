# Picture adjustment - testing

## Gate table

| Gate | Command | Device |
| --- | --- | --- |
| Unit + widget (feature) | `flutter test test/video_transform_state_test.dart test/video_transform_math_test.dart test/video_transform_panel_test.dart test/video_view_transform_test.dart test/screenshot_transform_wiring_test.dart` | none |
| Rule register | `pwsh -NoProfile -File scripts/check-video_transform-rules.ps1` | none |
| Analyzer | `flutter analyze` | none |
| Full suite | `flutter test` | none |

## What each gate proves

- `video_transform_state_test` - store defaults, independent axes, clamping,
  group reset, rotation cycle, per-field reset isolation, and media-sync reset
  (first report, a change, a `null` gap, a same-key remount).
- `video_transform_math_test` - quarter-turn/color mapping, flip matrix, capture
  predicate, and the PNG rotate-then-mirror math on a tiny image.
- `video_transform_panel_test` - the panel renders both control groups, a switch
  writes the store, reset is disabled when neutral, per-item reset buttons
  enable only when their field is non-default and reset only that field.
- `video_view_transform_test` - the surface gets `RotatedBox` for rotation, a
  paint `Transform` for mirroring, and neither when neutral; a media change
  resets, a same-key remount / `null` gap keeps.
- `screenshot_transform_wiring_test` - the capture core writes the
  post-processed bytes and falls back to the raw frame on failure.

Note: `flutter_zustand`'s `select` -> rebuild chain does not deliver under the
widget-test FakeAsync zone, so the panel tests mutate the store BEFORE pumping
(mirrors `frame_tools_float_panel_test`).

## Device checks (`M` rows)

Run on Windows desktop and Android, once per backend.

| Step | media_kit | fvp |
| --- | --- | --- |
| `M:media_kit color on Windows and Android` | Move each slider; the picture changes live, no stutter | - |
| `M:fvp color on Windows and Android` | - | Move each slider; the picture changes live and survives a file switch |
| `M:rotation at 90 degrees on both backends` | Rotate 90; picture is undistorted, fit still correct | same |
| `M:screenshot while mirrored` | Open a video, mirror horizontally, capture; the PNG is mirrored | screenshot is unsupported on fvp by design |

Also verify: mirror + 90 rotate reads as a display-space mirror; switching to the
next video returns the picture to neutral; re-opening the same media keeps the
adjustment; subtitles (rendered by mpv) are not mirrored.
