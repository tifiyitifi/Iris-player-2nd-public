import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/video_transform/model/enum/video_rotation.dart';
import 'package:iris/features/video_transform/model/video_transform_state.dart';
import 'package:iris/features/video_transform/services/video_transform_math.dart';
import 'package:iris/features/video_transform/store/video_transform_store.dart';
import 'package:iris/models/player.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

class VideoView extends HookWidget {
  const VideoView({
    super.key,
    required this.fit,
    this.mediaKey,
  });

  final BoxFit fit;
  final String? mediaKey;

  @override
  Widget build(BuildContext context) {
    final player = context.read<MediaPlayer>();
    // Narrow the subscription to the three fields this widget renders (the
    // whole-state guard in no_whole_state_app_state_select_test would flag
    // `(s) => s`). Color fields are applied by the player hooks, not here.
    final (bool, bool, VideoRotation) transformFields =
        useVideoTransformStore().select(
      context,
      (s) => (s.flipHorizontal, s.flipVertical, s.rotation),
    );
    final VideoTransformState transform = VideoTransformState(
      flipHorizontal: transformFields.$1,
      flipVertical: transformFields.$2,
      rotation: transformFields.$3,
    );

    // Picture adjustment is session-scoped: a NEW media starts from the
    // untouched picture so a mirror/rotation never leaks into the next video.
    // The store owns the tracker (not this widget) so the memory survives a
    // surface remount after a backend switch; the first report never resets.
    // `syncMediaKey` may reset the store. It runs during this build (a keyed
    // `useEffect` fires synchronously), but zustand delivers the change on an
    // async stream, so listeners are notified after the frame, not during it.
    useEffect(() {
      useVideoTransformStore().syncMediaKey(mediaKey);
      return null;
    }, [mediaKey]);

    final Widget surface = switch (player) {
      MediaKitPlayer player => Video(
          key: mediaKey != null ? ValueKey(mediaKey) : null,
          controller: player.controller,
          controls: NoVideoControls,
          fit: fit == BoxFit.none ? BoxFit.contain : fit,
        ),
      FvpPlayer player => FittedBox(
          fit: fit,
          child: SizedBox(
            width: player.width,
            height: player.height,
            child: VideoPlayer(player.controller),
          ),
        ),
      _ => Container(),
    };

    // Windows AXTree-crash mitigation (#103808 family): the video surface is
    // pure pixels to assistive tech, yet it is the single largest source of
    // per-frame semantics churn — exclude it from the accessibility bridge.
    // Stage 3: keep the outer ExcludeSemantics node stable across file
    // switches — only the inner Video is keyed so the tree does not replace
    // the semantics boundary itself (avoids a dangling AXTree node on every switch).
    return ExcludeSemantics(
      child: _applyVideoTransform(surface, transform),
    );
  }

  /// Rotation uses `RotatedBox` (layout-aware: it swaps the child's
  /// constraints, so `BoxFit`/fvp sizing/window fit stay correct); mirroring
  /// uses a paint-only `Transform` (a mirror never changes the bounding box).
  /// Order is rotate-then-mirror, i.e. flips are in display space.
  Widget _applyVideoTransform(Widget child, VideoTransformState transform) {
    Widget result = child;
    final int turns = videoTransformQuarterTurns(transform);
    if (turns != 0) {
      result = RotatedBox(quarterTurns: turns, child: result);
    }
    if (transform.flipHorizontal || transform.flipVertical) {
      result = Transform(
        alignment: Alignment.center,
        transform: videoTransformFlipMatrix(transform),
        child: result,
      );
    }
    return result;
  }
}
