# Picture adjustment - design

## Mechanism

The feature is split by what each layer can do without fighting the player:

| Concern | Mechanism | Why |
| --- | --- | --- |
| Mirror | Flutter `Transform` (paint-only) | a mirror never changes the bounding box |
| Rotation | Flutter `RotatedBox` (layout-aware) | swaps the child's constraints, so `BoxFit`, fvp sizing and desktop window fit stay correct |
| Color | backend color API | mpv VO properties / fvp controller effects |
| Saved frame | `image`-package post-process | the raw frame does not carry paint-level transforms |

`video_view.dart` wraps the surface as:

```
ExcludeSemantics( Transform( RotatedBox( surface ) ) )
```

- `RotatedBox(quarterTurns: rotation.quarterTurns)` is applied first.
- `Transform(alignment: center, transform: Matrix4.diagonal3Values(±1, ±1, 1))`
  is applied second, so mirrors are in display space.
- Both wrappers are skipped when their part is neutral, so a neutral state adds
  no render nodes at all.
- The tree stays under the existing `ExcludeSemantics`, preserving the Windows
  AXTree mitigation.

## Resets

Each field has a narrow reset method on the store: `resetFlipHorizontal`,
`resetFlipVertical`, `resetRotation`, `resetBrightness`, `resetContrast`,
`resetSaturation`. They delegate to the matching setter, so the clamp and
early-out behaviour is identical to dragging the control. The panel exposes one
trailing reset icon per row, disabled while that field is at its default;
"Reset all" remains at the bottom. Group resets (`resetOrientation`,
`resetColor`) stay internal and are not shown: two levels (item / all) are
enough (`0007`).

## Color mapping

The store's color fields are symmetric -1..1 with 0 = neutral.

| Backend | Call | Scale |
| --- | --- | --- |
| media_kit / mpv | `setProperty('brightness' \| 'contrast' \| 'saturation', value * 100)` | -100..100 |
| fvp | `controller.setBrightness / setContrast / setSaturation(value)` | -1..1 |

Color is applied from a `useEffect` keyed on the `(brightness, contrast,
saturation)` tuple. It is independent of the geometric transform, so dragging a
slider never rebuilds the surface. A backend without the property keeps its
default (best-effort, like `applyMpvSeekTuning`). media_kit also re-applies the
triple immediately after every `player.open`, because the VO equalizer can be
reset by a new file or a VO rebuild; fvp does the same after `initialize`.

## State

`VideoTransformState` is Freezed and runtime-only. `VideoTransformStore` is a
plain `Store`, not a `PersistentStore`. The store also owns the runtime media
tracker (`syncMediaKey`) instead of a widget-local `useRef`: a backend switch
remounts the video surface, which used to lose the previous-key memory.

- The first reported key never resets (a state set before the surface mounted
  must survive it).
- A `null` key ("nothing playing": a stop or a transient queue rebuild) is not
  a new media and keeps the session, so re-opening the SAME file through that
  gap keeps its adjustment.
- A different real key resets; re-reporting the same key — a surface remount —
  keeps the adjustment.

`video_view.dart` calls `syncMediaKey(mediaKey)` from an effect keyed on the
key, so the reset never notifies listeners during build.

## Saved frame

`captureFrameCore` takes an optional `PngPostProcessor`. The production caller
in `screenshot_service.dart` snapshots the store when the capture is REQUESTED,
skips the work when the transform is neutral, and otherwise runs
`buildScreenshotTransform`'s `applyVideoTransformPngJob` under `compute`.
Order matches the widget tree: rotate clockwise, then mirror. A decode failure
returns `null`, and the core writes the original bytes.

## Invariants

- No persisted state or Drift change.
- No `vf` filter chain and no `--video-rotate`: media_kit's pixel pipeline is
  untouched, so hardware decode is unaffected.
- The geometric transform is applied on exactly one layer (the Flutter surface);
  the backend never mirrors or rotates.
- The saved frame is the only place the transform is materialized a second time.
- Color and geometry are independent.

## Data model

```
VideoRotation { none(0), cw90(1), cw180(2), cw270(3) }

VideoTransformState {
  bool flipHorizontal
  bool flipVertical
  VideoRotation rotation
  double brightness   // -1..1, 0 neutral
  double contrast     // -1..1, 0 neutral
  double saturation   // -1..1, 0 neutral
}
```
