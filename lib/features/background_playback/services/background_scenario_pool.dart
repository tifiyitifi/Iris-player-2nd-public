import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/services/background_file_builder.dart';
import 'package:iris/features/background_playback/services/background_tag_pool.dart';
import 'package:iris/features/background_playback/services/current_foreground_media_key.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/path_conv.dart';

/// A WINDOW over the 副音 candidate stream.
///
/// 副音 never materializes the whole list into its queue: the runtime holds one
/// page of the reserved tag's view around the position it is playing, plus the
/// offset that page starts at ([start]) and the total stream size ([total]) so
/// step/jump can wrap and slide.
///
/// [focusIndex] / [focusKey] describe the item the window was centred on (or -1
/// / null when the caller supplied a plain list, or nothing is remembered):
/// [focusKey] is the remembered item's canonical media key, which is what a
/// caller feeds into `BackgroundQueueLogic.pickStartIndex` — the offset is only
/// meaningful against THIS page, the key is not.
class BgQueueWindow {
  const BgQueueWindow({
    required this.files,
    required this.start,
    required this.total,
    this.focusIndex = -1,
    this.focusKey,
  });

  final List<FileItem> files;
  final int start;
  final int total;

  /// Offset of the remembered item inside [files], or -1.
  final int focusIndex;

  /// Canonical media key of the remembered item, or null.
  final String? focusKey;

  /// A caller-supplied plain list, treated as a window at the head.
  factory BgQueueWindow.ofList(List<FileItem> files) =>
      BgQueueWindow(files: files, start: 0, total: files.length);
}

/// The 副音 candidate pool, resolved from the reserved 「副音备选」tag's VIEW.
///
/// 副音 is a tag play view (the SAME `TagViewResolver` the foreground uses),
/// pinned to the reserved tag: its candidate list is that tag's active
/// membership, ordered by the tag's own view state. The per-entry background
/// workspace scenario no longer carries sources — it is only the per-entry
/// position/repeat state container (see [BackgroundPlaybackStore]).
///
/// [pool] is unguarded (the foreground's own file is a legitimate member — the
/// 「音库」gesture tags the file you are watching for the NEXT foreground);
/// [guardedPool] applies the double-play guard for foreground-facing consumers.
class BackgroundScenarioPool {
  BackgroundScenarioPool();

  /// Window size: one page of the candidate stream. The tag view is resolved in
  /// one pass, so this is the part the runtime holds.
  static const int defaultCap = 400;

  static BackgroundScenarioPool? _shared;
  static BackgroundScenarioPool get shared =>
      _shared ??= BackgroundScenarioPool();

  /// The window of the candidate stream, centred on the item identified by
  /// [aroundKey] (a canonical media key — the playing file, carried across an
  /// ORDER CHANGE), else on [around] (a GLOBAL scenario index — the runtime
  /// passes the item it is playing so a reconcile never slides the page away
  /// from the current file), else on the position the active background
  /// workspace last recorded. Falls back to the head when none resolves.
  ///
  /// [aroundKey] exists because a numeric index is only meaningful against the
  /// order it was taken in: flipping the tag view's order (shuffle) left the
  /// old index pointing at unrelated content, so a lookup by index centred the
  /// page on the wrong page and the playing file was lost. The KEY is
  /// order-independent; [around] remains the fallback for a caller that has no
  /// key (and is the cheaper lookup).
  ///
  /// [BgQueueWindow.focusKey] still reports the REMEMBERED item, so a caller can
  /// order its preferences (playing item first, remembered position second)
  /// without a second resolve.
  ///
  /// Only the page is converted to playback files: the STREAM is already a
  /// materialized list (the tag resolver builds it in one pass), but the
  /// per-entry `FileItem` conversion — a storage lookup and a playable-URI build
  /// each — is the expensive half, and a step/jump slide used to pay it for
  /// every candidate in the library before throwing all but one page away.
  Future<BgQueueWindow> window({
    int size = defaultCap,
    int? around,
    String? aroundKey,
  }) async {
    final bg = await ensureBackgroundPlaybackWorkspace();
    final items = await resolveBackgroundCandidates(scenarioId: bg.id);
    final total = items.length;
    if (total == 0) {
      return const BgQueueWindow(files: [], start: 0, total: 0);
    }
    final rememberedKey = await _rememberedKey(bg.id);
    final focus = rememberedKey == null
        ? -1
        : items.indexWhere((it) {
            final media = it.media;
            return media is MediaFile &&
                backgroundItemMediaKey(media) == rememberedKey;
          });
    // Order-independent anchor: locate the playing item by key BEFORE falling
    // back to an index (which the caller may have taken in the old order).
    final keyIndex = (aroundKey == null || aroundKey.isEmpty)
        ? -1
        : items.indexWhere((it) {
            final media = it.media;
            return media is MediaFile &&
                backgroundItemMediaKey(media) == aroundKey;
          });
    final anchor = keyIndex >= 0 ? keyIndex : (around ?? focus);
    final start = anchor < 0 || anchor >= total ? 0 : (anchor ~/ size) * size;
    final end = start + size > total ? total : start + size;
    return BgQueueWindow(
      files: _filesOf(items.sublist(start, end)),
      start: start,
      total: total,
      focusIndex: focus >= start && focus < end ? focus - start : -1,
      focusKey: focus < 0 ? null : rememberedKey,
    );
  }

  /// The window (page) of the candidate stream that CONTAINS the global index
  /// [index] — the slide target when a step/jump lands outside the window
  /// currently held by the runtime. Same slice-then-convert rule as [window].
  Future<BgQueueWindow> windowAt(int index, {int size = defaultCap}) async {
    final bg = await ensureBackgroundPlaybackWorkspace();
    final items = await resolveBackgroundCandidates(scenarioId: bg.id);
    final total = items.length;
    final start = index < 0 ? 0 : (index ~/ size) * size;
    if (start >= total) {
      return BgQueueWindow(files: const [], start: start, total: total);
    }
    final end = start + size > total ? total : start + size;
    return BgQueueWindow(
      files: _filesOf(items.sublist(start, end)),
      start: start,
      total: total,
    );
  }

  /// The active background workspace's resolved head, as playback files.
  ///
  /// Kept for consumers that only need the file list (the picker, the live tag
  /// reconcile); the playback runtime uses [window] so it also learns where the
  /// list starts.
  Future<List<FileItem>> pool({int cap = defaultCap}) async =>
      (await window(size: cap)).files;

  /// [pool] with the foreground double-play guard applied — the shape every
  /// foreground-facing consumer wants (playback launch, the editor's prev/next,
  /// the picker, the browse surface).
  Future<List<FileItem>> guardedPool({int cap = defaultCap}) async {
    final files = await pool(cap: cap);
    final fgKey = excludedForegroundKey();
    if (fgKey == null) return List<FileItem>.of(files);
    return [
      for (final f in files)
        if (backgroundMediaKey(f) != fgKey) f,
    ];
  }

  /// No-op. The candidate stream is re-resolved from the tag view on demand; a
  /// membership change is announced through `BgPoolRevision`. Kept so
  /// the refresh/launch call sites keep their explicit "re-resolve" affordance.
  void invalidate() {}

  /// Playback files of a resolved candidate stream SLICE.
  ///
  /// The stream is the reserved tag's RAW membership (VM overlay is skipped), so
  /// every item is a real single file. A non-file item is skipped defensively.
  /// The storage lookup is memoized per storageId: a page holds one storage in
  /// practice, and the lookup is a linear scan.
  static List<FileItem> _filesOf(Iterable<EffectivePlaybackItem> items) {
    final out = <FileItem>[];
    final storages = <String, Storage?>{};
    for (final item in items) {
      final media = item.media;
      if (media is MediaFile) {
        out.add(backgroundFileItemFromMediaFile(media, storages: storages));
      }
    }
    return out;
  }

  /// The remembered item's canonical media key, read from the scenario state
  /// directly (the 副音 workspace has no sources, so it cannot be recovered
  /// through the scenario resolver).
  static Future<String?> _rememberedKey(String scenarioId) async {
    try {
      final state = await usePlaybackScenarioStore().getState(scenarioId);
      final occurrence = state?.currentPlaybackOccurrence;
      if (occurrence == null) return null;
      return canonicalKey(occurrence.storageId, occurrence.path);
    } catch (_) {
      return null;
    }
  }
}

/// Backwards-compatible alias for the retired `guardedBgPool()`.
Future<List<FileItem>> guardedBgPool() =>
    BackgroundScenarioPool.shared.guardedPool();
