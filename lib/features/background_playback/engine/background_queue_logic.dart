import 'dart:math';

import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/utils/path_conv.dart';

/// Canonical playback identity of a background candidate file.
///
/// Same shape as the playback-side canonical key the rest of the app uses for
/// per-file identity ([canonicalProgressKey]); used for the "never
/// double-play the foreground file" guard and for keeping the current item
/// across queue refreshes.
String backgroundMediaKey(FileItem file) =>
    canonicalProgressKey(file.storageId, file.path, uri: file.uri);

/// Result of a user-initiated queue jump ([BackgroundPlaybackStore.jumpTo]).
enum BgJumpOutcome {
  /// The jump happened.
  jumped,

  /// The row holds the foreground's own file, so playing it would run the same
  /// media on two engines. The row stays in the list (it is the 音库 source for
  /// the next foreground) — it just cannot play now.
  refusedForegroundFile,

  /// The run is off, or the index is out of range. Nothing to say.
  ignored,
}

/// Pure queue arithmetic for the background playback list (真单文件 only).
///
/// Phase 1/2 semantics: the queue is a plain ordered list of real files; the
/// player walks it with wrap rules chosen by [Repeat], skipping entries that
/// equal the foreground's current file ([excludedKey], code-level guard —
/// default ON, no UI in this iteration), and optional in-list shuffle.
abstract final class BackgroundQueueLogic {
  /// A shuffled copy of [source] (default shuffle semantics for 副音播放).
  static List<FileItem> shuffled(List<FileItem> source, {Random? random}) {
    final next = List<FileItem>.of(source);
    next.shuffle(random ?? Random());
    return next;
  }

  /// New index after stepping, or null when no step is possible.
  ///
  /// Rules:
  /// - empty queue → null;
  /// - [Repeat.none] never wraps past the ends (null at the boundary);
  /// - otherwise steps directionally through the queue, wrapping modulo
  ///   length, skipping every candidate whose media key equals
  ///   [excludedKey]; after a full lap with nothing eligible → null
  ///   (caller pauses rather than double-playing the foreground file);
  /// - [Repeat.one] → the current index (caller replays the same file).
  static int? stepIndex({
    required List<FileItem> queue,
    required int current,
    required bool forward,
    required Repeat repeat,
    String? excludedKey,
  }) {
    final n = queue.length;
    if (n == 0) return null;
    if (repeat == Repeat.one) {
      return (current >= 0 && current < n) ? current : 0;
    }
    // Repeat.none: walk directionally and NEVER wrap past an end. Skipping an
    // excluded candidate must stop at the boundary instead of modulo-wrapping
    // back to the other end (which would replay the head/tail).
    if (repeat == Repeat.none) {
      if (current < 0 || current >= n) return null;
      final step = forward ? 1 : -1;
      for (var i = current + step; i >= 0 && i < n; i += step) {
        final key = backgroundMediaKey(queue[i]);
        if (excludedKey != null && key == excludedKey) continue;
        return i;
      }
      return null;
    }
    for (var offset = 1; offset <= n; offset++) {
      final delta = forward ? offset : -offset;
      final candidate = (current + delta) % n;
      final idx = candidate < 0 ? candidate + n : candidate;
      final key = backgroundMediaKey(queue[idx]);
      if (excludedKey != null && key == excludedKey) continue;
      return idx;
    }
    return null;
  }

  /// Index a fresh or rewritten queue should START playing at, honouring the
  /// same-file guard exactly the way [stepIndex] does.
  ///
  /// The queue itself is the COMPLETE candidate pool — it deliberately keeps
  /// the foreground's own file (see [BackgroundPlaybackStore.resolveCandidatePool]
  /// for why) — so "may this play right now" is a question about the SELECTION,
  /// never about the listing. Every entry point that lands on a queue
  /// (enable / gate re-open / refresh / tag reconcile) funnels through here so
  /// the two concerns can never drift apart again.
  ///
  /// Prefers [preferredKey] (the file that was playing) when it survived AND
  /// can play, else the first playable entry, else the head. The head fallback
  /// is deliberate: a pool that is entirely the foreground file is a legal
  /// queue, and [BackgroundPlaybackStore.openGate] keeps what is loaded rather
  /// than dropping the run.
  ///
  /// Returns -1 only for an empty queue. A null [excludedKey] means the guard
  /// is lifted (`allowSameFgBgFile`), so nothing is filtered.
  static int pickStartIndex({
    required List<FileItem> queue,
    String? preferredKey,
    String? excludedKey,
  }) {
    if (queue.isEmpty) return -1;
    bool playable(int i) {
      if (excludedKey == null) return true;
      return backgroundMediaKey(queue[i]) != excludedKey;
    }

    if (preferredKey != null && preferredKey.isNotEmpty) {
      final at = queue.indexWhere((f) => backgroundMediaKey(f) == preferredKey);
      if (at >= 0 && playable(at)) return at;
    }
    for (var i = 0; i < queue.length; i++) {
      if (playable(i)) return i;
    }
    return 0;
  }

  /// Re-shuffles [queue] while anchoring [currentKey] (by media key) at the
  /// head so toggling shuffle never jumps the user to an unrelated file.
  /// Falls back to a plain shuffle when the anchor is absent.
  static List<FileItem> reshuffleKeepingCurrent(
    List<FileItem> queue,
    String? currentKey, {
    Random? random,
  }) {
    if (queue.isEmpty) return queue;
    final anchorIndex = currentKey == null
        ? -1
        : queue.indexWhere((f) => backgroundMediaKey(f) == currentKey);
    if (anchorIndex < 0) {
      return shuffled(queue, random: random);
    }
    final rest = <FileItem>[
      for (var i = 0; i < queue.length; i++)
        if (i != anchorIndex) queue[i],
    ]..shuffle(random ?? Random());
    return [queue[anchorIndex], ...rest];
  }
}
