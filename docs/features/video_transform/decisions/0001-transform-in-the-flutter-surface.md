# 0001 - The geometric transform lives in the Flutter surface

- Status: accepted
- Date: 2026-11-22

## Context

Both backends can rotate/mirror at the pixel level (mpv `vf`/`--video-rotate`,
FFmpeg transposes), but doing so:

- forces a hardware-decode download/copy-back,
- couples media_kit's reported `video-params.rotate` with the display rotation,
- splits semantics: mpv flips in source space, fvp has no public flip API,
- makes the two backends behave differently.

## Decision

Mirror and rotation are applied once, in the Flutter surface:

- rotation with `RotatedBox` (layout-aware; fixes `BoxFit`, fvp sizing and the
  desktop window fit without manual dimension swaps),
- mirror with a paint-only `Transform`,
- order fixed to rotate-then-mirror (display space).

The backend pixel pipeline is not touched.

## Consequences

- Identical behaviour on media_kit and fvp.
- No hardware-decode penalty and no `vf`/`--video-rotate` coupling.
- The saved frame needs a post-process to match the screen (`0004`).
- Rotation is limited to quarter turns.

## Rejected

- `vf=hflip` + `--video-rotate` on media_kit only: screenshot WYSIWYG, but
  backend divergence, copy-back cost and the rotate coupling.
- A raw `Matrix4` rotation: paint-only, so fit and window sizing break.
