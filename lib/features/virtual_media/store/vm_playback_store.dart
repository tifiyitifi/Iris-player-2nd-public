import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:flutter_zustand/flutter_zustand.dart';

part 'vm_playback_store.freezed.dart';

/// Reactive snapshot of an active Virtual Merge playback session.
///
/// Pure presentation/coordination state — the resume ANCHOR lives in the
/// database (`virtual_media_states`), never here.
@freezed
abstract class VmPlaybackState with _$VmPlaybackState {
  const factory VmPlaybackState({
    /// Currently playing virtual item; null = no active session.
    VirtualMediaItem? item,

    /// Index into [item.segments].
    @Default(0) int segmentIndex,

    /// Sibling virtual items of this session in DISPLAYED merged order (all
    /// rules, stream order); lets next/previous advance exactly as the list
    /// shows it.
    @Default(<VirtualMediaItem>[]) List<VirtualMediaItem> queue,
    @Default(0) int queueIndex,

    /// Last fatal session error message (consecutive segment failures).
    @Default(null) String? lastError,

    /// Target intra-segment position (ms) for the segment switch currently
    /// in flight. Set by [jumpToSegment]/[advance], consumed once by the
    /// player hooks after open (open-with-position): null = ordinary open
    /// with legacy DB-resume behavior; 0 = sequential switch from segment
    /// start; >0 = slider cross-segment jump into the middle of a segment.
    @Default(null) int? pendingSeekMs,

    /// True while a segment switch is in flight (feed pushed, new file not
    /// yet seeked). The UI freezes the scrubber on the target virtual
    /// position instead of showing the new file's 0% pre-seek state.
    @Default(false) bool transitioning,

    /// Whether the LAST segment/item change came from a user seek
    /// ([VirtualMediaController.jumpToSegment]) rather than a natural advance
    /// or a boundary step. The 副音 link uses it to let the progress lock own
    /// seek-driven 副音 mapping and only start a new 副音 file per block on
    /// natural transitions.
    @Default(false) bool lastSwitchWasSeek,
  }) = _VmPlaybackState;
}

VmPlaybackStore useVmPlaybackStore() =>
    create(() => VmPlaybackStore());

class VmPlaybackStore extends Store<VmPlaybackState> {
  VmPlaybackStore() : super(const VmPlaybackState());

  /// Value-deduped replace: backfill patches rebuild the item on every probe,
  /// so identical snapshots must not wake listeners.
  void replace(VmPlaybackState next) {
    if (next == state) return;
    set(next);
  }
}
