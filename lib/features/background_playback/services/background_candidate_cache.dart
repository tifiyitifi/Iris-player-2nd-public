import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/model/db/repositories/bg_source_rule_repository.dart';
import 'package:iris/features/background_playback/model/source/bg_source_rule.dart';
import 'package:iris/features/background_playback/services/bg_source_revision.dart';
import 'package:iris/features/background_playback/services/background_source_resolver.dart';
import 'package:iris/features/background_playback/services/current_foreground_media_key.dart';
import 'package:iris/features/background_playback/store/bg_source_prefs.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/tag_play/playback/tag_voice_candidate_source.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';

/// Session-scoped resolved 副音 candidate pool (bounded by the resolver cap).
///
/// A resolution can scan up to `maxScanItems` media rows, so it runs ONCE per
/// source-rules revision and is served from memory afterwards. The pool is
/// UNGUARDED (no double-play filter) — consumers (playback launch, the editor,
/// the browse surface) apply the foreground guard themselves.
///
/// Invalidation: the cache key folds the serialized rules, the dedupe switch
/// and [BgSourceRevision] — the coalesced signal that a tag the rules read from
/// changed its members. A rule edit/enable/pin toggle, a dedupe flip or a
/// relevant membership write therefore re-resolves on the next read, and
/// [invalidate] forces it outright. Library content is still not tracked:
/// a media row appearing/disappearing surfaces on the next rule revision, a
/// relevant membership write, or an explicit refresh.
class BackgroundCandidateCache {
  BackgroundCandidateCache({
    BgSourceRuleRepository? ruleRepo,
    TagPlayRepository? tagRepo,
    MediaNodeRepository? nodeRepo,
    Future<bool> Function()? dedupeOf,
    int Function()? sourceRevisionOf,
  })  : _ruleRepo = ruleRepo ?? DbModule.bgSourceRuleRepo,
        _tagRepo = tagRepo ?? DbModule.tagPlayRepo,
        _nodeRepo = nodeRepo ?? DbModule.mediaNodeRepo,
        _dedupeOf = dedupeOf ?? BgSourcePrefs.autoDedupe,
        _sourceRevisionOf =
            sourceRevisionOf ?? (() => BgSourceRevision.shared.revision);

  /// Shared session instance (DbModule-backed). Tests construct their own.
  static BackgroundCandidateCache? _shared;
  static BackgroundCandidateCache get shared =>
      _shared ??= BackgroundCandidateCache();

  final BgSourceRuleRepository _ruleRepo;
  final TagPlayRepository _tagRepo;
  final MediaNodeRepository _nodeRepo;
  final Future<bool> Function() _dedupeOf;

  /// Coalesced "a tag my sources read from changed" counter, folded into the
  /// cache key so the next read re-resolves. Injected in tests.
  final int Function() _sourceRevisionOf;

  String? _key;
  List<FileItem>? _pool;

  /// In-flight resolutions keyed by fingerprint. A single slot would let two
  /// concurrent different-key reads clobber each other, leaving `_key`/`_pool`
  /// set by whichever finished last (and possibly an older rules revision).
  final Map<String, Future<List<FileItem>>> _inflight = {};

  /// The resolved pool (unguarded). Concurrent callers share one in-flight
  /// resolution instead of stampeding the library scan.
  Future<List<FileItem>> pool({
    int cap = BackgroundSourceResolver.defaultCap,
  }) async {
    final rules = await _ruleRepo.loadRules();
    final dedupe = await _dedupeOf();
    final key = _fingerprint(
      rules,
      dedupe: dedupe,
      cap: cap,
      sourceRevision: _sourceRevisionOf(),
    );
    final hit = _pool;
    if (hit != null && _key == key) return hit;
    final existing = _inflight[key];
    if (existing != null) return existing;
    final future = _resolve(cap: cap, dedupe: dedupe);
    _inflight[key] = future;
    try {
      final files = List<FileItem>.unmodifiable(await future);
      _key = key;
      _pool = files;
      return files;
    } finally {
      _inflight.remove(key);
    }
  }

  /// Drops the cached pool; the next read re-resolves. Any in-flight future is
  /// detached so an explicit refresh is not served by a stale resolution.
  void invalidate() {
    _key = null;
    _pool = null;
    _inflight.clear();
  }
  Future<List<FileItem>> _resolve({
    required int cap,
    required bool dedupe,
  }) async {
    final resolution = await BackgroundSourceResolver(
      tagRepo: _tagRepo,
      nodeRepo: _nodeRepo,
      ruleRepo: _ruleRepo,
    ).resolve(cap: cap, dedupe: dedupe);
    if (resolution.hasActiveRules) return resolution.files;
    // Zero-active fallback: the built-in library pure-tag source.
    return TagVoiceCandidateSource(
      tagRepo: _tagRepo,
      nodeRepo: _nodeRepo,
    ).resolveCandidates(cap: cap);
  }

  /// Cache identity: everything that can change the resolved pool, nothing
  /// cosmetic (rule names/descriptions never affect resolution).
  static String _fingerprint(
    List<BgSourceRule> rules, {
    required bool dedupe,
    required int cap,
    int sourceRevision = 0,
  }) {
    final sb = StringBuffer(
      'cap=$cap;dedupe=${dedupe ? 1 : 0};src=$sourceRevision;n=${rules.length};',
    );
    for (final r in rules) {
      sb
        ..write(r.id)
        ..write(r.enabled ? '|e1' : '|e0')
        ..write('|${r.kind.name}|${r.pinned ? 1 : 0}')
        ..write('|tag=${r.tagId}')
        ..write('|mode=${r.matchMode.name}')
        ..write('|paths=${r.paths.join(',')}')
        ..write('|pat=${[for (final p in r.patterns) p.toJson()]}')
        ..write('|tf=${r.tagFilterEnabled ? 1 : 0}:${r.filterTagId}')
        ..write('|file=${r.fileStorageId}:${r.filePath}')
        ..write('|sort=${r.sortField.name}:${r.sortDirection.name}:${r.sortOrder};');
    }
    return sb.toString();
  }
}

/// Session pool with the double-play guard applied — the shape every
/// foreground-facing consumer wants (playback launch, the editor's
/// prev/next, the picker, the browse surface). The raw cache stays unguarded.
Future<List<FileItem>> guardedBgPool() async {
  final pool = await BackgroundCandidateCache.shared.pool();
  final fgKey = excludedForegroundKey();
  if (fgKey == null) return List<FileItem>.of(pool);
  return [
    for (final f in pool)
      if (backgroundMediaKey(f) != fgKey) f,
  ];
}
