# 0004 - Bake orientation into the saved frame

- Status: accepted
- Date: 2026-11-22

## Context

Screenshots are captured from the backend (`player.screenshot`), which returns
the decoded frame with no knowledge of the Flutter paint transform. A mirrored
or rotated surface would therefore save an unmirrored, unrotated frame.

## Decision

`captureFrameCore` takes an optional `PngPostProcessor`. The production caller
reads the session state:

- neutral orientation -> return the bytes unchanged (no decode),
- otherwise -> `compute(applyVideoTransformPngJob, ...)`, order rotate-then-mirror,
- decode failure -> `null`, and the core writes the original frame.

## Consequences

- Saved frame is WYSIWYG for geometry.
- The transform math is shared with nothing else; it is unit-tested on a tiny
  image.
- The cost is one decode/encode on the isolate, only when orientation is active.

## Rejected

- Failing the capture when the post-process fails: losing the shot is worse.
- Applying the post-process on the UI isolate: a 1080p decode would jank.
