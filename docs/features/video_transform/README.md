# Picture adjustment (video transform)

Status: **in progress**, working branch.

Picture adjustment lets the viewer mirror, rotate and re-grade the picture that
is on screen right now, from the player's **More -> 画面调整** entry. It is a
viewing adjustment, not a preference: it applies to the current video only and
returns to neutral when the media changes or the app restarts.

This document says what the reader sees. `spec.md` says what must be true,
`design.md` says how it is built, `rules.md` names the cases that hold it.

## Scope

In scope:

- horizontal and vertical mirror;
- clockwise quarter-turn rotation (0 / 90 / 180 / 270);
- brightness, contrast and saturation;
- reset (all, or per group);
- the saved-frame (screenshot) carrying the same orientation;
- both backends: media_kit and fvp.

Out of scope:

- persistence across videos or launches;
- arbitrary angle rotation, crop, zoom, shear;
- per-file profiles or presets;
- applying the adjustment to the independent Sub Audio engine, the desktop
  dock or picture-in-picture (foreground player only);
- color grading inside the saved frame beyond what the backend already renders.

## Version facts

| Fact | Value |
| --- | --- |
| Shipped in | v2.1.2 |
| Platforms | Android, Windows (Linux builds pass CI) |
| Backends | media_kit (mpv) and fvp |
| State lifetime | session only; reset on media change and restart |
| Settings namespace | none (deliberately not a meta-setting) |
| Persisted state | none |
| Drift schema | unchanged |

## Reading order

1. `spec.md` - requirements.
2. `design.md` - mechanism and invariants.
3. `rules.md` - the case register.
4. `recurrences.md` - what keeps coming back.
5. `testing.md` - how to prove it.
6. `decisions/` - why, and what was rejected.

## Code map

| Path | Role |
| --- | --- |
| `lib/features/video_transform/model/` | Freezed state and the rotation enum |
| `lib/features/video_transform/store/` | session store (runtime-only) |
| `lib/features/video_transform/services/video_transform_math.dart` | pure turn/matrix/color mapping and the PNG post-process |
| `lib/features/video_transform/services/video_transform_apply.dart` | per-backend color application |
| `lib/features/video_transform/view/video_transform_panel.dart` | the panel opened from More |
| `lib/pages/player/video_view.dart` | applies `RotatedBox` + `Transform` to the surface |
| `lib/hooks/player/use_media_kit_player.dart`, `use_fvp_player.dart` | apply color live |
| `lib/features/playback_tools/services/screenshot_service.dart` | bakes orientation into the saved PNG |
| `lib/pages/player/control_bar/control_bar_widgets/more_menu_button.dart` | the More entry |

## Neighbouring behaviours

- Screenshots are a media_kit-only capability; picture adjustment does not
  change that, it only orients the captured frame.
- Display fit (`BoxFit`, desktop display modes) is untouched: rotation is
  layout-aware, so fit still describes the picture, not the window.
