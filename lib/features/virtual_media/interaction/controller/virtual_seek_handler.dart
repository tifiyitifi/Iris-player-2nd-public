import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';

/// Seek translation for all sliders (single entry point §5/§6).
///
/// - Sliders pass virtual (position, totalDuration); this layer decomposes.
/// - Inside same segment: real-time seek.
/// - Cross-segment drag: no picture change during drag, only preview
///   “将跳转第X段 name 内 pos/dur 外 pos/total”; commit on release.
/// - Drag back to same segment → simple internal seek.
/// - Drag beyond ends → clamp to 0%/100% of current segment.
class VirtualSeekHandler {
  const VirtualSeekHandler();

  /// Local engine position -> virtual timeline base (ms).
  ///
  /// Single choke point for every RELATIVE move (backward/forward, step
  /// buttons): callers must never add [deltaMs] to a raw local position and
  /// feed it to [seekVirtual]/`seek` (which interpret it as virtual) — that
  /// coordinate mix-up jumps to the wrong segment. Pure: no singleton, fully
  /// unit-testable. Out-of-range inputs clamp into the item.
  int virtualBaseMs(
    VirtualMediaItem item, {
    required int segmentIndex,
    required int localMs,
  }) {
    if (item.segments.isEmpty || item.totalDurationMs <= 0) return 0;
    final segIdx = segmentIndex.clamp(0, item.segments.length - 1);
    final segDur = item.segments[segIdx].durationMs ?? 0;
    final saneLocal = localMs.clamp(0, segDur > 0 ? segDur : 0);
    return (item.offsetOf(segIdx) + saneLocal).clamp(0, item.totalDurationMs);
  }

  /// Whether the segment [segmentIndex] of [item] carries a REAL duration.
  ///
  /// Every intra-segment clamp is meaningless without it: any candidate target
  /// collapses to 0 (`clampVmLocalMs` returns 0 for an unknown duration), and a
  /// caller that seeks/persists that fabricated 0 wipes the file's saved
  /// progress (「VM 里按一下 ←/→ 进度归 0」). Callers must HOLD instead of
  /// seeking. Duration is unknown until the VM scan/notification has probed the
  /// physical file.
  bool segmentDurationKnown(VirtualMediaItem item, int segmentIndex) {
    if (item.segments.isEmpty) return false;
    final idx = segmentIndex.clamp(0, item.segments.length - 1);
    final dur = item.segments[idx].durationMs;
    return dur != null && dur > 0;
  }

  /// Resolves a relative move on the virtual timeline (ms precision).
  ///
  /// Returns the clamped virtual target decomposed to `(segIdx, localMs,
  /// virtualMs)` — or NULL when the move cannot be resolved: a virtual total of
  /// zero (nothing probed yet) or a target segment with no known duration. A
  /// caller MUST treat null as "do nothing": the degenerate `(0, 0, 0)` this
  /// used to return was fed to a user seek and persisted position 0 over the
  /// file's saved progress. Exact segment boundaries resolve to the LATER
  /// segment (same rule as [VirtualMediaItem.locate]); head/tail clamp instead
  /// of wrapping.
  ({int segIdx, int localMs, int virtualMs})? resolveRelativeSeek(
    VirtualMediaItem item, {
    required int segmentIndex,
    required int localMs,
    required int deltaMs,
  }) {
      if (item.segments.isEmpty || item.totalDurationMs <= 0) return null;
    // The source segment's position is meaningless without a real duration: any
    // base derived from it is fabricated (the old `clamp(0, 0)` collapsed the
    // current position to the segment start and wiped saved progress). Hold
    // instead of seeking, exactly like an unknown target segment.
    if (!segmentDurationKnown(item, segmentIndex)) return null;
    final base = virtualBaseMs(item, segmentIndex: segmentIndex, localMs: localMs);
    final target = (base + deltaMs).clamp(0, item.totalDurationMs);
    final (idx, local) = item.locate(target);
    if (!segmentDurationKnown(item, idx)) return null;
    final clamped = clampVmLocalMs(item.segments[idx].durationMs, local);
    // Report the ACTUAL landing, not the (possibly unseekable) clamped-to-total
    // target: otherwise the OSD / persisted position sit one ms past the last
    // seekable ms of the segment and fire an instant `completed`.
    return (segIdx: idx, localMs: clamped, virtualMs: item.offsetOf(idx) + clamped);
  }

  /// Local buffered amount -> virtual buffered amount (ms) for the progress
  /// bar, whose scale is the virtual total. Same clamp contract as above.
  int virtualBufferMs(
    VirtualMediaItem item, {
    required int segmentIndex,
    required int rawBufferMs,
  }) {
    if (item.segments.isEmpty || item.totalDurationMs <= 0) return 0;
    final segIdx = segmentIndex.clamp(0, item.segments.length - 1);
    return (item.offsetOf(segIdx) + rawBufferMs.clamp(0, 1 << 30))
        .clamp(0, item.totalDurationMs);
  }

  /// Immediate seek (tap / same-segment drag tick).
  Future<void> seekVirtual(
    Duration virtualPos, {
    required void Function(Duration local) rawSeek,
  }) async {
    final ctrl = VirtualMediaController.instance;
    if (!ctrl.isActive) {
      rawSeek(virtualPos);
      return;
    }
    await ctrl.seekFromUi(virtualPos, rawSeek: rawSeek);
  }

  /// Whether a drag from [fromVirtualMs] to [toVirtualMs] would cross
  /// segments — used to decide preview-only vs live seek.
  bool isCrossSegment(int fromVirtualMs, int toVirtualMs) {
    final ctrl = VirtualMediaController.instance;
    final item = ctrl.state.item;
    if (item == null || !ctrl.isActive) return false;
    final (a, _) = item.locate(fromVirtualMs);
    final (b, _) = item.locate(toVirtualMs);
    return a != b;
  }

  /// Preview payload for the floating overlay during cross-segment drag.
  ({int segIdx, String name, int localMs, int segDurMs, int virtualMs, int totalMs})?
      preview(int virtualPosMs) {
    final ctrl = VirtualMediaController.instance;
    final item = ctrl.state.item;
    if (item == null || item.segments.isEmpty || !ctrl.isActive) return null;
    final (idx, local) = item.locate(virtualPosMs);
    final seg = item.segments[idx];
    return (
      segIdx: idx,
      name: seg.name,
      localMs: local,
      segDurMs: seg.durationMs ?? 0,
      virtualMs: virtualPosMs.clamp(0, item.totalDurationMs),
      totalMs: item.totalDurationMs,
    );
  }

  /// Commit on finger lift: jump carrying the intra-segment offset so the
  /// new file opens WITH the target position (no 0% flash).
  Future<void> commitCrossSegment(int virtualPosMs) async {
    final ctrl = VirtualMediaController.instance;
    final item = ctrl.state.item;
    if (item == null || !ctrl.isActive) return;
    final (idx, local) = item.locate(virtualPosMs);
    await ctrl.jumpToSegment(idx, localMs: local);
  }
}
