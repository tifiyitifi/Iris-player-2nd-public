/// Fixed-offset foreground↔副音 mapping for 进度锁定 (`full`).
///
/// The 副音 queue is treated as ONE continuous timeline: its files are
/// concatenated by duration, and a foreground seek maps onto it through a fixed
/// offset captured while the two runtimes are aligned. A target that overflows
/// the current 副音 file therefore rolls into the next one — or wraps to an
/// earlier one under repeat-all — and lands at the corresponding local
/// position, exactly like a single media carrying a second audio track.
///
/// Pure and unit-testable: the runtime observer only wires the results to the
/// engine/store.
library;

/// Concatenated durations of the 副音 queue (`prefixMs[i]` = virtual start of
/// index `i`; length == n + 1).
///
/// Durations are best-effort: an unknown file contributes 0 ms and therefore
/// collapses in the timeline, and a target landing on it plays from 0 — a
/// documented graceful degradation (the alternative, refusing to follow, would
/// be worse).
class BgQueueTimeline {
  BgQueueTimeline(List<int> durationsMs, {Set<int> unknownIndices = const <int>{}})
      : durationsMs = List<int>.unmodifiable(
          durationsMs.map((d) => d < 0 ? 0 : d),
        ),
        unknownIndices = Set<int>.unmodifiable(
          unknownIndices.where((i) => i >= 0 && i < durationsMs.length),
        ),
        prefixMs = _buildPrefix(durationsMs);

  final List<int> durationsMs;

  /// Indices whose duration could NOT be resolved (a missing `media_nodes`
  /// duration, a pending probe, or a probe failure). The 副音 queue marks them
  /// explicitly so the mapping can STAND DOWN instead of fabricating a 0 — see
  /// [tryVirtualPositionOf]. A 0 duration is indistinguishable from "unknown"
  /// for a real file, so both count as unknown here.
  final Set<int> unknownIndices;

  /// `prefixMs[i]` = virtual start offset of queue index `i`.
  final List<int> prefixMs;

  static List<int> _buildPrefix(List<int> durations) {
    final out = List<int>.filled(durations.length + 1, 0);
    for (var i = 0; i < durations.length; i++) {
      out[i + 1] = out[i] + (durations[i] < 0 ? 0 : durations[i]);
    }
    return out;
  }

  bool get isEmpty => durationsMs.isEmpty;
  int get length => durationsMs.length;
  int get totalMs => prefixMs.isEmpty ? 0 : prefixMs.last;

  /// True when at least one entry lacks a duration.
  bool get hasUnknown => unknownIndices.isNotEmpty;

  /// Whether [index]'s own duration is known.
  bool knownAt(int index) =>
      index >= 0 &&
      index < length &&
      !unknownIndices.contains(index) &&
      durationsMs[index] > 0;

  /// Whether the VIRTUAL mapping can be trusted THROUGH [index]: the timeline is
  /// usable and every entry up to and including it carries a duration (those are
  /// the prefix offsets the mapping is built from).
  bool mappingUsableThrough(int index) {
    if (isEmpty || totalMs <= 0 || index < 0) return false;
    final upto = index >= length ? length - 1 : index;
    for (var i = 0; i <= upto; i++) {
      if (unknownIndices.contains(i) || durationsMs[i] <= 0) return false;
    }
    return true;
  }

  /// Whether a TOTAL/wrap-based mapping (a cross-file roll) can be trusted: the
  /// modulo over an understated total would land on the wrong entry.
  bool get fullyKnown {
    if (isEmpty || totalMs <= 0) return false;
    for (var i = 0; i < length; i++) {
      if (unknownIndices.contains(i) || durationsMs[i] <= 0) return false;
    }
    return true;
  }

  int offsetOf(int index) =>
      (index < 0 || index >= prefixMs.length) ? 0 : prefixMs[index];

  /// Virtual ms of `(index, localMs)`, clamped into the queue.
  ///
  /// NOTE: an unknown-duration entry collapses to 0 here (a documented graceful
  /// degradation for the foreground queue). Callers that must not act on a
  /// fabricated position — the 副音 position mirror — use
  /// [tryVirtualPositionOf] instead.
  int virtualPositionOf(int index, int localMs) {
    if (isEmpty) return 0;
    final i = index.clamp(0, length - 1);
    final local = localMs.clamp(0, durationsMs[i]);
    return (offsetOf(i) + local).clamp(0, totalMs);
  }

  /// Virtual ms of `(index, localMs)`, or NULL when that entry's duration is
  /// unknown (or the index is out of range).
  ///
  /// The NULL is the point: 副音's position must never be fabricated as 0, which
  /// collapsed the mapping onto the queue head and let the continuous drift
  /// correction drag the VIDEO there (「开启副音把播放进度归 0」).
  int? tryVirtualPositionOf(int index, int localMs) {
    if (isEmpty || index < 0 || index >= length) return null;
    if (unknownIndices.contains(index) || durationsMs[index] <= 0) return null;
    final local = localMs.clamp(0, durationsMs[index]);
    return (offsetOf(index) + local).clamp(0, totalMs);
  }

  /// Maps a virtual position to `(index, localMs)`; the LATER entry wins at a
  /// boundary (the same rule as `VirtualMediaItem.locate`).
  (int, int) locate(int virtualMs) {
    if (isEmpty) return (0, 0);
    final pos = virtualMs.clamp(0, totalMs);
    if (length == 1) return (0, pos);
    var lo = 0;
    var hi = length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (prefixMs[mid] <= pos) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return (lo, pos - prefixMs[lo]);
  }
}

/// Whether a cross-file continuation may be published for the OPEN queue entry
/// at [index]: the mapped landing must be trusted, so every duration up to and
/// including that entry has to be known ([BgQueueTimeline.mappingUsableThrough]).
///
/// An unknown prefix collapses those entries to 0 ms in [BgQueueTimeline.offsetOf],
/// which understates the entry's virtual start and would publish a WRONG pin
/// (frozen until the durations resolve). Skipping the continuation for this
/// flush lets the normal seek path handle it and defers the pin to a later,
/// trusted alignment.
bool bgContinuationPublishable(BgQueueTimeline timeline, int index) =>
    index >= 0 && timeline.mappingUsableThrough(index);

/// A resolved foreground→副音 mapping target.
class BgLockTarget {
  const BgLockTarget(
    this.fileIndex,
    this.localMs,
    this.virtualMs,
    this.wrapped,
  );

  final int fileIndex;
  final int localMs;
  final int virtualMs;

  /// True when an overflowing target was wrapped to the queue head.
  final bool wrapped;

  @override
  bool operator ==(Object other) =>
      other is BgLockTarget &&
      other.fileIndex == fileIndex &&
      other.localMs == localMs &&
      other.virtualMs == virtualMs &&
      other.wrapped == wrapped;

  @override
  int get hashCode => Object.hash(fileIndex, localMs, virtualMs, wrapped);

  @override
  String toString() =>
      'BgLockTarget(file: $fileIndex, local: $localMs, virtual: $virtualMs, wrapped: $wrapped)';
}

/// Whether the resolved target leaves the current 副音 file (queue rollover).
bool bgLockTargetRolls(BgLockTarget target, int currentIndex) =>
    target.fileIndex != currentIndex;

/// The cross-file CONTINUATION target under [BgExhaustedAction.nextBg]: where
/// the 副音 timeline should continue for the current foreground position
/// [fgMs], walking the queue as ONE looping timeline and preserving the fixed
/// [offsetMs] (the pair's alignment).
///
/// This is the completion / empty-alignment path, deliberately SEPARATE from
/// the user-seek mapping ([resolveLockTarget] called with `wrap: true`): the
/// foreground is the master here too, but the 副音 file has just ENDED (or the
/// alignment left the current fg position with no bg content), so the queue
/// must wrap onto the entry carrying the same virtual position rather than
/// restart the next file at its own 00:00 (which would silently re-anchor the
/// offset). Returns null when the queue has no known duration to locate in.
///
/// [wrap] carries the 副音 list's own repeat setting: `Repeat.all` loops the
/// list, every other mode stops at its end. With it off, a target that ran past
/// the LAST entry clamps onto that entry's tail — the caller must treat "at or
/// past the list end with no wrap" as exhausted (nothing left to continue
/// with), never as a landing to resume on.
({int index, int localMs})? resolveBgContinuation({
  required int fgMs,
  required int offsetMs,
  required BgQueueTimeline timeline,
  bool wrap = true,
}) {
  if (timeline.isEmpty || timeline.totalMs <= 0) return null;
  final t = resolveLockTarget(
    fgMs: fgMs,
    offsetMs: offsetMs,
    timeline: timeline,
    wrap: wrap,
  );
  return (index: t.fileIndex, localMs: t.localMs);
}

/// Virtual 副音 position a foreground moment maps to (`fgMs - offsetMs`),
/// unclamped. Callers compare it against `timeline.totalMs` to tell a real
/// landing from "past the end of the list" (see [resolveBgContinuation]).
int bgVirtualTargetMs({required int fgMs, required int offsetMs}) =>
    fgMs - offsetMs;

/// Maps `fgMs` onto the 副音 queue under a fixed `offsetMs`.
///
/// `bgVirtual = fgMs - offsetMs`. A negative target clamps to the queue head —
/// or counts BACK through the list when [wrapBackward] is on (the "fg jumped
/// back to 00:00, so 副音 must re-derive where it lands" case). An overflow
/// wraps (modulo the queue total) only under [wrap], otherwise it clamps to the
/// last file's end.
///
/// [wrap] and [wrapBackward] both carry the 副音 list's own repeat setting
/// (`Repeat.all` = allow crossing file boundaries), so the mapping can never
/// loop a list the user pinned to a single pass; [wrapBackward] additionally
/// stays off under the 仅当前 scope, where the mapped position is bounded by the
/// foreground file's own window.
BgLockTarget resolveLockTarget({
  required int fgMs,
  required int offsetMs,
  required BgQueueTimeline timeline,
  bool wrap = false,
  bool wrapBackward = false,
}) {
  if (timeline.isEmpty) return const BgLockTarget(0, 0, 0, false);
  final total = timeline.totalMs;
  var target = fgMs - offsetMs;
  var wrapped = false;
  if (target < 0) {
    if (wrapBackward && total > 0) {
      // Dart's `%` on ints already returns a non-negative result for a positive
      // divisor, so this is "count back from the end": the earlier file the
      // elapsed bg durations land in.
      target = target % total;
      wrapped = true;
    } else {
      target = 0;
    }
  } else if (target >= total) {
    // `>=`: at EXACTLY the queue end (`target == total`, which is where a
    // lockstep natural completion of the LAST file lands) a wrap must still go
    // to the head. Clamping to the last file's end would re-select that same
    // file and re-complete it forever instead of looping the list — the
    // "repeat-all keeps replaying one bg" symptom.
    if (wrap && total > 0) {
      target = target % total;
      wrapped = true;
    } else {
      target = total;
    }
  }
  final (idx, local) = timeline.locate(target);
  return BgLockTarget(idx, local, target, wrapped);
}

/// Local-ms ceiling for the 副音 file at [currentIndex] under 仅当前 scope.
///
/// The mapped foreground position must stay within the foreground file's
/// 0–100%: `bgVirtual + offsetMs <= fgDurMs`, i.e. `bgVirtual <= fgDurMs -
/// offsetMs`. Converted to the current file's local axis via the queue
/// prefix, clamped into `[0, fileDurMs]`. Null when the bound cannot be
/// computed (empty/zero timeline, bad index, unknown foreground duration) —
/// the caller then leaves the 副音 seek free.
int? bgSeekCeilingLocalMs({
  required BgQueueTimeline timeline,
  required int currentIndex,
  required int offsetMs,
  required int fgDurMs,
}) {
  if (timeline.isEmpty || timeline.totalMs <= 0) return null;
  if (fgDurMs <= 0) return null;
  if (currentIndex < 0 || currentIndex >= timeline.length) return null;
  final fileDurMs = timeline.durationsMs[currentIndex];
  if (fileDurMs <= 0) return null;
  final virtualCeiling = fgDurMs - offsetMs;
  final local = virtualCeiling - timeline.offsetOf(currentIndex);
  return local.clamp(0, fileDurMs);
}

/// Local-ms floor for the 副音 file at [currentIndex] under 仅当前 scope.
///
/// The bg position mapped to the foreground 00:00: `bgVirtual = -offsetMs`.
/// Before it 副音 does not exist (the fg window starts where the alignment
/// starts), so a bg seek must not go below it. Converted to the current file's
/// local axis and clamped into `[0, fileDurMs]`. Null when the bound cannot be
/// computed — the caller then leaves the lower bound free.
int? bgSeekFloorLocalMs({
  required BgQueueTimeline timeline,
  required int currentIndex,
  required int offsetMs,
}) {
  if (timeline.isEmpty || timeline.totalMs <= 0) return null;
  if (currentIndex < 0 || currentIndex >= timeline.length) return null;
  final fileDurMs = timeline.durationsMs[currentIndex];
  if (fileDurMs <= 0) return null;
  final virtualFloor = -offsetMs;
  final local = virtualFloor - timeline.offsetOf(currentIndex);
  return local.clamp(0, fileDurMs);
}
