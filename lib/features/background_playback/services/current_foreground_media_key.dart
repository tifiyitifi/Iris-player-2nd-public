import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/path_conv.dart';

/// Canonical media key of the file the FOREGROUND player currently holds
/// (mirrors the play-queue's synthetic single-item shape), or null when no
/// foreground media is loaded.
///
/// 副音 uses this as the double-play guard: a background candidate that equals
/// the foreground file is skipped rather than played twice on two engines.
String? currentForegroundMediaKey() {
  final state = usePlayQueueStore().state;
  final queue = state.playQueue;
  final index = state.currentIndex;
  if (queue.isEmpty || index < 0) return null;
  final currentPlayIndex = queue.indexWhere((e) => e.index == index);
  if (currentPlayIndex < 0 || currentPlayIndex >= queue.length) return null;
  final FileItem file = queue[currentPlayIndex].file;
  return canonicalProgressKey(file.storageId, file.path, uri: file.uri);
}

/// [currentForegroundMediaKey] for 作用范围 purposes.
///
/// While a Virtual Merge session runs under `wholeVirtual`, the VM link
/// publishes the whole virtual video's identity as
/// [BackgroundPlaybackState.vmScopeKeyOverride]; scope decisions (apply-to-
/// current, anchors) must use that same identity or the toggle and the anchor
/// would disagree on every block switch.
String? currentScopeKey() {
  final override = useBackgroundPlaybackStore().state.vmScopeKeyOverride;
  if (override != null && override.isNotEmpty) return override;
  return currentForegroundMediaKey();
}

/// [currentForegroundMediaKey] as a double-play EXCLUSION for 副音 queue math:
/// returns null while [BackgroundPlaybackState.allowSameFgBgFile] is on (the
/// user allowed the same file on both runtimes), otherwise the foreground key.
///
/// Every launch/step/advance guard should consume THIS so the meta row is the
/// single authority over the same-file policy.
String? excludedForegroundKey() {
  final bg = useBackgroundPlaybackStore().state;
  if (bg.allowSameFgBgFile) return null;
  return currentForegroundMediaKey();
}
