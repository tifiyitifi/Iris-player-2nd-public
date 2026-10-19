import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/file.dart';
import 'package:iris/utils/path_conv.dart';

/// Canonical playback identity of a background candidate file.
///
/// Same shape as the playback-side canonical key the rest of the app uses for
/// per-file identity ([canonicalProgressKey]); used for the "never
/// double-play the foreground file" guard and for keeping the current item
/// across queue refreshes.
String backgroundMediaKey(FileItem file) =>
    canonicalProgressKey(file.storageId, file.path, uri: file.uri);

/// Canonical playback identity of a candidate STREAM entry (the resolver's
/// `MediaFile`), without building the playback `FileItem` for it.
///
/// MUST agree with [backgroundMediaKey] applied to the FileItem
/// `backgroundFileItemFromMediaFile` builds for the same entry: the window uses
/// this to locate the remembered/playing item across the WHOLE stream, and
/// converting every candidate just to compute its key is the expensive half of a
/// page slide (a playable URI is rebuilt per entry).
///
/// Agreement holds by construction: `canonicalProgressKey` ignores the uri
/// whenever the path is non-empty, and for the path-less (SAF) case both sides
/// carry the same raw uri.
String backgroundItemMediaKey(MediaFile f) =>
    canonicalProgressKey(f.storageId, f.path, uri: f.uri);

/// The `media_nodes.path` form of a background candidate: its storage-relative
/// path, or its SAF document uri when the path is empty.
///
/// A SAF single-picked file (`ACTION_OPEN_DOCUMENT`) has NO segment path, so the
/// document uri is its identity — and the DB row stores exactly that as the
/// canonical path (see `MediaNodeDriftAdapter.toCompanion` / [occurrencePath]).
/// Every path-KEYED read and write (`media_nodes` lookup, duration write-back)
/// must use this same form, or a write lands on the wrong single pick while the
/// reader keys it by uri: the asymmetry that left every SAF row flagged unknown.
///
/// `canonicalProgressKey`'s uri fallback answers the KEY question
/// ([backgroundMediaKey]); this answers the DB-path question for the same file.
String backgroundOccurrencePath(FileItem file) =>
    file.path.isNotEmpty ? file.path.join('/') : file.uri;

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
/// The queue is a plain ordered list of real files — a WINDOW over the scenario
/// stream (see `BgQueueWindow`); the runtime walks it by GLOBAL scenario index
/// and slides the window, skipping entries that equal the foreground's current
/// file ([excludedKey], code-level guard, default ON). Shuffle is owned by the
/// background scenario's own order, never by this logic.
abstract final class BackgroundQueueLogic {
  /// Index a fresh or rewritten queue should START playing at, honouring the
  /// same-file guard exactly the way a step does.
  ///
  /// The queue itself is the COMPLETE candidate pool — it deliberately keeps
  /// the foreground's own file (see [BackgroundScenarioPool], which explains
  /// why the 音库 gesture requires it) — so "may this play right now" is a
  /// question about the SELECTION, never about the listing. Every entry point that lands on a queue
  /// (enable / gate re-open / refresh / tag reconcile) funnels through here so
  /// the two concerns can never drift apart again.
  ///
  /// Prefers the first entry of [preferredKeys] that survived AND can play,
  /// else the first playable entry, else the head. The list is ORDERED — the
  /// caller decides the precedence (the file that is playing now, then the
  /// position the run was last left at) — and every candidate goes through the
  /// SAME guard, so a remembered item that equals the foreground file can
  /// never be selected here. The head fallback is deliberate: a pool that is
  /// entirely the foreground file is a legal queue, and
  /// [BackgroundPlaybackStore.openGate] keeps what is loaded rather than
  /// dropping the run.
  ///
  /// Returns -1 only for an empty queue. A null [excludedKey] means the guard
  /// is lifted (`allowSameFgBgFile`), so nothing is filtered.
  static int pickStartIndex({
    required List<FileItem> queue,
    List<String> preferredKeys = const <String>[],
    String? excludedKey,
  }) {
    if (queue.isEmpty) return -1;
    bool playable(int i) {
      if (excludedKey == null) return true;
      return backgroundMediaKey(queue[i]) != excludedKey;
    }

    for (final key in preferredKeys) {
      if (key.isEmpty) continue;
      final at = queue.indexWhere((f) => backgroundMediaKey(f) == key);
      if (at >= 0 && playable(at)) return at;
    }
    for (var i = 0; i < queue.length; i++) {
      if (playable(i)) return i;
    }
    return 0;
  }
}
