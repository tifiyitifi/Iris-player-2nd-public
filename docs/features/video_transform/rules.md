# Picture adjustment - rule register

The normative cases. `spec.md` owns the requirement; this file owns the case
that holds it. `design.md` holds the mechanism behind a rule.

Columns:

- **Case** - the situation, in one line.
- **Evidence** - what the row has to show for the behaviour to be allowed.
- **Behaviour** - what the feature must do. Normative.
- **Why** - the reason this is a rule.
- **Coverage** - `;`-separated tokens in one cell:
  - `F:<file>#<test name>` - a literal test in `test/<file>.dart`; it must fail
    when the rule breaks. `scripts/check-video_transform-rules.ps1` resolves
    every token.
  - `F:<file>` - a file-level fallback for parameterised or generated tests.
  - `D:<nnnn>` - the governing decision record.
  - `M:<step>` - a human device check named in `testing.md`.
  - `-:<reason>` - deliberately not held by an executable test.

A rule that stops being true is **superseded**, not deleted.

## ENTRY - where the panel lives

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| VT-1 | More menu entry | The panel opens from More | THE SYSTEM SHALL offer the "picture adjustment" entry in the player More menu on both backends | a low-frequency viewing adjustment must not occupy a control-bar slot | `-:menu wiring; the panel itself is covered by VT-13`; `D:0006` |

## ORIENT - mirror and rotation

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| VT-2 | Default picture | Nothing is applied | WHEN the store is fresh, THE SYSTEM SHALL have no mirror, no rotation and neutral color | a fresh session must show the untouched video | `F:video_transform_state_test#defaults to the untouched picture`; `D:0002` |
| VT-3 | Independent mirror axes | Each switch stands alone | WHEN a mirror switch is toggled, THE SYSTEM SHALL mirror only that axis | the two axes are separate user intents | `F:video_transform_state_test#toggling a mirror flips only its own axis` |
| VT-4 | Rotation is quarter turns | Four clockwise steps | WHEN rotation cycles, THE SYSTEM SHALL advance clockwise through 0/90/180/270 and wrap | hardware decode and every backend agree on quarter turns | `F:video_transform_state_test#rotation cycles clockwise through four steps`; `D:0001` |
| VT-5 | Rotation is layout-aware | `RotatedBox` in the tree | WHEN a quarter-turn is active, THE SYSTEM SHALL rotate with `RotatedBox` so layout still fits the rotated picture | a paint-only rotation would break `BoxFit` and window sizing | `F:video_view_transform_test#video view applies a RotatedBox for quarter-turn rotation`; `D:0001` |
| VT-6 | Mirror is paint-only | `Transform` in the tree | WHEN a mirror is active, THE SYSTEM SHALL mirror with a paint-only `Transform` | a mirror must not change the bounding box | `F:video_view_transform_test#video view applies a mirror Transform only when flipped`; `D:0001` |
| VT-7 | Neutral surface | No extra nodes | WHEN the state is neutral, THE SYSTEM SHALL leave the surface without a rotation or mirror wrapper | a neutral session must not pay for or risk the transform | `F:video_view_transform_test#video view leaves the surface untouched when neutral` |
| VT-8 | Rotate before mirror | Display-space mirror | WHEN rotation and mirror are both active, THE SYSTEM SHALL rotate first, then mirror | a source-space mirror after a 90-degree turn reads as the wrong axis | `F:video_transform_math_test#png job rotates clockwise before mirroring`; `D:0005` |

## COLOR - brightness, contrast, saturation

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| VT-9 | Symmetric range | -1..1, 0 neutral | WHEN a color setter is called, THE SYSTEM SHALL clamp into -1..1 and treat NaN as neutral | one number must map to both backend scales | `F:video_transform_state_test#color setters clamp into -1..1 and treat NaN as neutral`; `D:0003` |
| VT-10 | Backend scales | -100..100 / -1..1 | WHEN color is applied, THE SYSTEM SHALL scale media_kit by 100 and pass fvp its native range | the two backends use different numeric ranges | `F:video_transform_math_test#quarter turns and color scale map to both backend ranges`; `D:0003` |
| VT-11 | Color is independent | Geometry untouched | WHEN only color changes, THE SYSTEM SHALL not rebuild or alter the geometric transform | slider drags must stay smooth and never move the picture | `F:video_transform_math_test#capture is affected by orientation but not color`; `D:0003` |

## RESET - lifetime and reset

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| VT-12 | Group reset | Only the named group | WHEN a reset is requested, THE SYSTEM SHALL clear only the named group, or all groups | separate orientation and color reset are useful on their own | `F:video_transform_state_test#reset clears only the group it names` |
| VT-13 | Session only | Not persisted | THE SYSTEM SHALL keep picture adjustment out of storage and reset it when the media changes or the app restarts | carrying a mirror into the next video would silently flip everything | `F:video_transform_state_test#defaults to the untouched picture`; `F:video_view_transform_test#changing the media resets the adjustment`; `D:0002` |
| VT-28 | Media tracker survives a remount | Same key keeps, a real change clears | WHEN the surface reports the same media again after a remount or a `null` gap, THE SYSTEM SHALL keep the adjustment; WHEN it reports a different media, THE SYSTEM SHALL reset | a widget-local record is lost on a backend switch, and a stop is not a new media | `F:video_transform_state_test#media sync keeps the session across a null gap and resets on a change`; `F:video_view_transform_test#a media change while the surface is unmounted still resets`; `F:video_view_transform_test#a surface remount keeps the adjustment for the same media`; `F:video_view_transform_test#a null media gap does not drop the adjustment`; `D:0008` |

## PANEL - the controls

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| VT-14 | Controls present | Both groups | WHEN the panel opens, THE SYSTEM SHALL show the mirror switches, the four rotations and the three color sliders | the panel is the only surface for the feature | `F:video_transform_panel_test#panel renders orientation and color controls` |
| VT-15 | Toggle writes state | The switch drives the store | WHEN the horizontal mirror switch is tapped, THE SYSTEM SHALL update the store | the UI must be a thin view over state | `F:video_transform_panel_test#toggling the horizontal mirror updates the store` |
| VT-16 | Reset disabled when neutral | Nothing to clear | WHEN the picture is untouched, THE SYSTEM SHALL disable the reset action | an enabled no-op button reads as a bug | `F:video_transform_panel_test#reset is disabled on the untouched picture` |

## PER-ITEM RESET - clearing one control at a time

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| VT-25 | Single-field reset | Only that field moves | WHEN a per-item reset is called, THE SYSTEM SHALL restore only that field to its default | resetting one control must not undo unrelated adjustments | `F:video_transform_state_test#each per-field reset clears only its own value`; `D:0007` |
| VT-26 | Reset button availability | Disabled at default | WHEN a field is at its default, THE SYSTEM SHALL disable its reset button; otherwise THE SYSTEM SHALL enable it | an enabled no-op reads as a bug | `F:video_transform_panel_test#per-item reset buttons are disabled only for default values`; `D:0007` |
| VT-27 | Reset is narrow | Other fields survive | WHEN a per-item reset button is tapped, THE SYSTEM SHALL leave every other field untouched | the user asked to clear one control, not the picture | `F:video_transform_panel_test#tapping a per-item reset leaves the other fields intact`; `D:0007` |

## CAPTURE - the saved frame

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| VT-17 | Orientation is baked | Saved PNG matches the screen | WHEN a screenshot is captured with an orientation transform, THE SYSTEM SHALL save the transformed frame | the raw frame does not carry paint-level transforms | `F:screenshot_transform_wiring_test#captureFrameCore writes the post-processed bytes`; `D:0004` |
| VT-18 | Neutral capture | Raw frame | WHEN the orientation transform is neutral, THE SYSTEM SHALL save the raw frame unchanged | no needless decode/encode | `F:video_transform_math_test#neutral png job returns the input unchanged` |
| VT-19 | Decode failure falls back | The shot still lands | IF the post-process cannot decode, THEN THE SYSTEM SHALL save the original frame | losing a screenshot to a transform bug is worse than a mismatched frame | `F:screenshot_transform_wiring_test#a failing post-processor keeps the original frame` |
| VT-20 | Mirror math | Pixels move | WHEN a horizontal mirror is applied to the saved frame, THE SYSTEM SHALL swap the columns | the saved frame must match the mirrored surface | `F:video_transform_math_test#png job mirrors horizontally` |
| VT-29 | A shot uses the request-time transform | No late rotation lands in the file | WHEN a screenshot is requested, THE SYSTEM SHALL snapshot the picture transform and SHALL post-process the frame with that snapshot only | the frame bytes arrive after the request, so re-reading the store could bake a rotation the screen never showed | `F:video_transform_math_test#screenshot snapshot is neutral -> no post-processor`; `F:video_transform_math_test#screenshot snapshot keeps the state it was built from`; `F:screenshot_transform_wiring_test#the saved frame uses the transform sampled at request time` |

## DEVICE - checks that need real media

| ID | Case | Evidence | Behaviour | Why | Coverage |
| --- | --- | --- | --- | --- | --- |
| VT-21 | media_kit color applies | The picture changes | THE SYSTEM SHALL apply brightness/contrast/saturation on the media_kit backend | mpv VO property support varies by output driver | `M:media_kit color on Windows and Android` |
| VT-22 | fvp color applies | The picture changes | THE SYSTEM SHALL apply brightness/contrast/saturation on the fvp backend | the fvp effects reset on open, so re-apply must be verified | `M:fvp color on Windows and Android` |
| VT-23 | Rotation keeps fit | No stretch or crop | WHEN rotated 90 degrees, THE SYSTEM SHALL keep the picture undistorted | `RotatedBox` is layout-aware but the backends size differently | `M:rotation at 90 degrees on both backends` |
| VT-24 | Screenshot is WYSIWYG | Mirrored shot | WHEN mirrored, THE SYSTEM SHALL save a mirrored screenshot | the post-process runs off the raw frame | `M:screenshot while mirrored` |
