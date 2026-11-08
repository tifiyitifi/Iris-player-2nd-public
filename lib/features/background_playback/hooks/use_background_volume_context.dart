import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/model/domain/media_ratio.dart';
import 'package:iris/features/background_playback/services/background_ratio_resolver.dart';
import 'package:iris/features/background_playback/services/background_volume_policy.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/fake_cut/core/fake_cut_background_scope.dart';
import 'package:iris/features/fake_cut/store/use_fake_cut_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

/// Build-phase snapshot of the 副音 volume policy inputs (sub_media §5.5).
///
/// [ratio] is the EFFECTIVE pair for the foreground media — the per-media
/// override when one exists, else the global pair, or 100/100 when the user
/// cleared "use saved ratio". Every engine volume site (both player hooks, the
/// 副音 scope, the float panel) reads this so the two layers resolve in exactly
/// one place.
typedef BackgroundVolumeContext = ({
  /// 副音 is ACTIVELY mixing right now (subsystem on AND user gate open and not
  /// exhausted). False ⇒ the foreground must play like a plain single-track
  /// player: master volume only, no fg ratio, no track mute.
  bool active,
  bool fgMuted,
  bool bgMuted,
  String? fgKey,
  MediaRatio ratio,
});

/// Canonical media key of the foreground file, reactive to the play queue.
String? useForegroundRatioKey(BuildContext context) {
  final queue = usePlayQueueStore().select(context, (s) => s.playQueue);
  final index = usePlayQueueStore().select(context, (s) => s.currentIndex);
  // Memoize the O(n) index lookup: this hook runs on every foreground player
  // build (per position frame), and the queue/index only change on navigation.
  return useMemoized(() {
    if (queue.isEmpty || index < 0) return null;
    final i = queue.indexWhere((e) => e.index == index);
    if (i < 0 || i >= queue.length) return null;
    return backgroundMediaKey(queue[i].file);
  }, [queue, index]);
}

BackgroundVolumeContext useBackgroundVolumeContext(
  BuildContext context, {
  String? fgKeyOverride,
}) {
  final bg = useBackgroundPlaybackStore();
  final snapshot = bg.select(context, (s) => (
        enabled: s.enabled,
        gateOpen: s.gateOpen,
        bgExhausted: s.bgExhausted,
        outOfScope: s.bgOutOfScope,
        queueEnded: s.bgQueueEnded,
        fgMuted: s.fgMuted,
        bgMuted: s.bgMuted,
        ratioEnabled: s.volumeRatioEnabled,
        globalFg: s.fgVolumePercent,
        globalBg: s.bgVolumePercent,
        perMedia: s.perMediaRatio,
        mappedFile: s.mappedFile,
        mappedFg: s.mappedFgPercent,
        mappedBg: s.mappedBgPercent,
        editing: s.segmentEditMode,
        draftFg: s.segmentEditDraft?.fgPercent,
        draftBg: s.segmentEditDraft?.bgPercent,
      ));
  // 简播 (fake cut): the cut owns the picture and a virtual timeline that no
  // 副音 pairing describes, so the pair is inactive for THIS media even though
  // the gate stays open. Without it the foreground stayed ducked to 30% during
  // a cut.
  final fgKey = fgKeyOverride ?? useForegroundRatioKey(context);
  final bool fakeCutActive = fakeCutBlocksBackground(
    fgKey,
    useFakeCutStore().select(context, (FakeCutStoreState s) => s.playingKey),
  );
  // The most specific split wins: the segment being EDITED (so the align
  // panel's sliders are audible), else the active mapping segment's own pair;
  // then the per-media / global fallback.
  MediaRatio? pairOf(int? fg, int? bg) => (fg == null || bg == null)
      ? null
      : MediaRatio(fgPercent: fg, bgPercent: bg);
  final MediaRatio? segmentOverride = snapshot.editing
      ? pairOf(snapshot.draftFg, snapshot.draftBg)
      : (snapshot.mappedFile != null
          ? pairOf(snapshot.mappedFg, snapshot.mappedBg)
          : null);
  final ratio = resolveEffectiveRatio(
    volumeRatioEnabled: snapshot.ratioEnabled,
    global: MediaRatio(
      fgPercent: snapshot.globalFg,
      bgPercent: snapshot.globalBg,
    ),
    perMedia: snapshot.perMedia,
    fgKey: fgKey,
    segmentOverride: segmentOverride,
  );
  return (
    // 副音 mixes (and ducks the foreground) only while the user gate is OPEN
    // AND the pair actually applies to what is playing. Feature-armed-but-
    // stopped, the terminal "exhausted" run, a queue that ran off its end, a
    // media outside the 作用范围 and a 简播 cut all read as inactive: the
    // foreground plays at master again.
    active: BackgroundVolumePolicy.active(
      enabled: snapshot.enabled,
      gateOpen: snapshot.gateOpen,
      exhausted: snapshot.bgExhausted,
      queueEnded: snapshot.queueEnded,
      outOfScope: snapshot.outOfScope || fakeCutActive,
    ),
    fgMuted: snapshot.fgMuted,
    bgMuted: snapshot.bgMuted,
    fgKey: fgKey,
    ratio: ratio,
  );
}
