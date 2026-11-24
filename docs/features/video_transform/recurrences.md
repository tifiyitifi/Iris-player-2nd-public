# Picture adjustment - recurrences

Symptoms and couplings that keep coming back. This is not a changelog.

## The transform leaks into the next video

Symptom: a user mirrors one video, opens the next one, and it is still
mirrored.

Cause: treating the adjustment as a preference (persisted) instead of a viewing
adjustment, or resetting only on app restart.

Guard: VT-13/VT-28 and the `syncMediaKey` reset on `VideoTransformStore`. The
tracker lives on the store, not in a widget `useRef`, so it survives a surface
remount (backend switch). A first report must not reset (it would clobber a
state set before the surface mounts); a later DIFFERENT key does, while a
`null` gap keeps the session.

## A paint transform is applied to the wrong layer

Symptom: the picture is mirrored but the gestures or the OSD are also mirrored,
or the picture is stretched after a 90-degree turn.

Cause: wrapping the gesture/overlay layer instead of only the video surface, or
using a paint-only `Transform` for rotation (which leaves constraints alone).

Guard: `video_view.dart` wraps only the surface, under `ExcludeSemantics`;
rotation uses `RotatedBox` (VT-5, VT-6).

## Rotation and mirror combine into the wrong axis

Symptom: after a 90-degree rotation, "mirror horizontally" mirrors vertically on
screen.

Cause: mirroring in source space before rotating, or applying the backend's
rotation after the Flutter mirror.

Guard: the composition order is fixed to rotate-then-mirror, in both the widget
tree and the PNG job (VT-8).

## Color and geometry fight each other

Symptom: dragging a color slider makes the picture jump, or clears the mirror.

Cause: rebuilding a single filter chain that carries both concerns, or writing
the whole state from one control.

Guard: color is applied through a tuple-keyed effect that never touches the
geometric wrappers (VT-11).

## Color resets while the slider keeps its value

Symptom: brightness/contrast/saturation is set, but after a reopen, a fullscreen
change or a return from the background the picture is neutral while the sliders
still show the old values.

Cause: mpv's VO equalizer can be reset by a new file / a VO rebuild, and the
color effect only ran when the triple changed.

Guard: `use_media_kit_player.dart` re-asserts the session color after every
`player.open` (fvp already re-applies after `initialize`). Best-effort: an
output driver without the properties keeps the picture untouched.

## The saved frame does not match the screen

Symptom: a mirrored video produces an unmirrored screenshot.

Cause: the backend saves the raw decoded frame; paint-level transforms are not
in it.

Guard: `captureFrameCore`'s `PngPostProcessor` (VT-17..VT-20). The neutral case
must stay a pass-through, and a decode failure must fall back to the raw frame.
The state is snapshotted when the capture is requested, not when the frame
bytes arrive: a rotation changed during the grab must not be baked into a shot
of the previous picture (VT-29).

## One reset clears everything

Symptom: the user removes an accidental mirror and loses the color settings
they had just tuned.

Cause: a single "Reset all" action with no narrow alternative.

Guard: per-item reset icons on each row (VT-25..VT-27, `0007`). Group resets are
intentionally not surfaced so there are only two levels: item and all.

## Re-opening the same media clears the adjustment

Symptom: seeking to the end and letting the file re-open resets the mirror.

Cause: resetting on every `mediaKey` evaluation instead of only on a *change*.

Guard: the store-level previous-key comparison (`syncMediaKey`), which is not
lost when the surface remounts and does not reset on a same-key re-report.
