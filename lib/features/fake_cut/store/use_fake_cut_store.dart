import 'dart:convert';
import 'dart:io';

import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/services/fake_cut_discovery.dart';
import 'package:iris/features/fake_cut/services/fake_cut_plan_builder.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/kv/kv_keys.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/store/persistent_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart' show canonicalProgressKey;
import 'package:path/path.dart' as p;

final _log = AreaKeyLog(LogKeys.legacyPlayer);

/// Identity of a playing file inside the fake-cut store.
///
/// The same canonical key the progress columns use, so the remembered plan and
/// the saved source progress always agree on WHICH file they describe.
String fakeCutFileKey(FileItem file) =>
    canonicalProgressKey(file.storageId, file.path, uri: file.uri);

/// Sentinel for [FakeCutStoreState.copyWith]: lets an explicit `null` clear a
/// nullable field (the usual `?? this.field` would silently keep the old value).
const Object _unset = Object();

/// 简播 store state.
///
/// Two lifetimes live here on purpose:
///  * [activePaths] is PERSISTED (per-window session KV) — "this window plays
///    file X with plan Y" survives a restart;
///  * [plansByFile] / [activePlans] are a RUNTIME cache of parsed projects, so
///    the tab and the player never parse the same `.llc` twice.
class FakeCutStoreState {
  const FakeCutStoreState({
    this.revision = 0,
    this.plansByFile = const <String, List<FakeCutPlanSource>>{},
    this.discovering = const <String, bool>{},
    this.scannedDurationMs = const <String, int>{},
    this.activePaths = const <String, String>{},
    this.activePlans = const <String, FakeCutPlan>{},
    this.activePlanSignatures = const <String, String>{},
    this.playingKey,
  });

  /// Bumped ONLY by an explicit user activation/deactivation. The player hook
  /// watches this to reopen the media — a background scan or a lazily
  /// materialized plan must never trigger a second open.
  final int revision;

  /// fileKey → the projects found for that file: its OWN plans (`bound`) first,
  /// then the directory's unmatched ones (`!bound`), which the tab renders in
  /// its collapsed 「无匹配计划」 section and can never activate.
  final Map<String, List<FakeCutPlanSource>> plansByFile;

  final Map<String, bool> discovering;

  /// fileKey → the source duration the cached scan was built with.
  ///
  /// The tab scans as soon as the file is bound, which is often BEFORE the
  /// container duration is probed: the plan then reports an unclamped total and
  /// misses the "ranges past the end" notice. Keying the cache on this lets the
  /// same scan run again once the duration is known.
  final Map<String, int> scannedDurationMs;

  /// fileKey → absolute `.llc` path (persisted).
  final Map<String, String> activePaths;

  /// fileKey → materialized plan (runtime).
  final Map<String, FakeCutPlan> activePlans;

  /// fileKey → `mtime:size` of the `.llc` the materialized plan came from, so an
  /// edited project is re-read instead of replaying the old plan.
  final Map<String, String> activePlanSignatures;

  /// The fileKey whose OPEN actually adopted a cut in this window, or null.
  ///
  /// Runtime only, and deliberately separate from [activePaths]: that map says
  /// which plan is REMEMBERED for a file, while this says the EDL really owns
  /// the picture right now. The two differ whenever the cut cannot be prepared
  /// (unwritable temp dir, vanished source), the open belongs to another
  /// backend, or a Virtual-Media session holds the timeline. 副音 and the tab
  /// read THIS, so a remembered-but-dead plan no longer suspends anything.
  final String? playingKey;

  FakeCutStoreState copyWith({
    int? revision,
    Map<String, List<FakeCutPlanSource>>? plansByFile,
    Map<String, bool>? discovering,
    Map<String, int>? scannedDurationMs,
    Map<String, String>? activePaths,
    Map<String, FakeCutPlan>? activePlans,
    Map<String, String>? activePlanSignatures,
    Object? playingKey = _unset,
  }) =>
      FakeCutStoreState(
        revision: revision ?? this.revision,
        plansByFile: plansByFile ?? this.plansByFile,
        discovering: discovering ?? this.discovering,
        scannedDurationMs: scannedDurationMs ?? this.scannedDurationMs,
        activePaths: activePaths ?? this.activePaths,
        activePlans: activePlans ?? this.activePlans,
        activePlanSignatures:
            activePlanSignatures ?? this.activePlanSignatures,
        playingKey: identical(playingKey, _unset)
            ? this.playingKey
            : playingKey as String?,
      );
}

/// Per-window 简播 state (plan list + which plan the current media plays with).
///
/// The plan itself is never stored: the `.llc` file is the source of truth, and
/// the progress columns keep the SOURCE position. Only "which project belongs to
/// this file" is remembered.
class FakeCutStore extends PersistentStore<FakeCutStoreState> {
  FakeCutStore() : super(const FakeCutStoreState());

  /// A scan request that arrived while another one was in flight.
  ///
  /// The tab runs `discover()` twice in quick succession: on bind, and again
  /// when the container probe lands. On a slow folder listing the second call
  /// used to be dropped by the in-flight guard, so the plan kept the
  /// "duration unknown" answer (unclamped totals, no "past the end" notice)
  /// until the user switched files or pressed refresh. The request that the
  /// in-flight pass CANNOT answer is replayed when it lands.
  final Map<String, _PendingScan> _pending = <String, _PendingScan>{};

  @override
  Future<FakeCutStoreState?> load() async {
    final String? raw =
        await getSessionKvStore().read(key: KvKeys.fakeCutActivePlans);
    if (raw == null || raw.isEmpty) return null;
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final Map<String, String> paths = <String, String>{};
    decoded.forEach((Object? key, Object? value) {
      if (key is String && value is String && key.isNotEmpty) {
        paths[key] = value;
      }
    });
    return FakeCutStoreState(activePaths: paths);
  }

  @override
  Future<void> save(FakeCutStoreState state) async {
    await getSessionKvStore().write(
      key: KvKeys.fakeCutActivePlans,
      value: jsonEncode(state.activePaths),
    );
  }

  /// Persist the (small) active-path map. Gated on [loadOk]: a store whose load
  /// threw must never replace another window's data with its empty default.
  Future<void> _persistActivePaths() async {
    if (!loadOk) {
      _log.w('fake cut: skip persist, store never loaded');
      return;
    }
    try {
      await save(state);
    } catch (e) {
      _log.w('fake cut: persist failed: $e');
    }
  }

  List<FakeCutPlanSource> plansFor(String fileKey) =>
      state.plansByFile[fileKey] ?? const <FakeCutPlanSource>[];

  bool isDiscovering(String fileKey) => state.discovering[fileKey] ?? false;

  String? activePathFor(String fileKey) => state.activePaths[fileKey];

  FakeCutPlan? activePlanFor(String fileKey) => state.activePlans[fileKey];

  /// Records which file's open actually adopted a cut (null when none did).
  ///
  /// Runtime only: never persisted, and it does NOT bump [revision] — this is
  /// an observation of the open, not a user switch, so it must never reopen the
  /// media.
  void noteCutPlaying(String? fileKey) {
    if (state.playingKey == fileKey) return;
    set(state.copyWith(playingKey: fileKey));
  }

  /// Whether [fileKey]'s open really plays a cut right now.
  bool isCutPlaying(String? fileKey) =>
      fileKey != null && state.playingKey == fileKey;

  /// Scans the video's folder for `.llc` projects. Results are cached per file;
  /// [force] re-reads (the tab's refresh button).
  ///
  /// The cache also remembers the SOURCE DURATION the scan ran with: the tab
  /// binds the file before the container is probed, so a plan built with an
  /// unknown duration is not a finished answer (unclamped totals, no "past the
  /// end" notice) and must be re-read once the duration arrives.
  Future<void> discover(FileItem file, {bool force = false}) async {
    final String key = fakeCutFileKey(file);
    final int probedMs = file.durationMs ?? 0;
    if (state.discovering[key] == true) {
      // The in-flight pass was built for the duration IT started with. Queue
      // the request only when that pass cannot answer it: a known-but-newer
      // duration (the probe landing), or a forced refresh. A stale/lower value
      // (an older FileItem snapshot) is already covered by the better answer.
      final int inFlightMs = state.scannedDurationMs[key] ?? 0;
      if (force || probedMs > inFlightMs) {
        _pending[key] = _PendingScan(file: file, force: force);
      }
      return;
    }
    if (!force &&
        state.plansByFile.containsKey(key) &&
        state.scannedDurationMs[key] == probedMs) {
      return;
    }
    set(state.copyWith(
      discovering: <String, bool>{...state.discovering, key: true},
    ));
    List<FakeCutPlanSource> sources;
    try {
      // One list per video: its own projects first-class, plus the directory's
      // unmatched ones (they belong to NO video here) flagged — listed, but
      // never applied to this file.
      final List<FakeCutPlanSource> own = await FakeCutDiscovery.scan(
        videoPath: file.uri,
        sourceDurationMs: file.durationMs,
      );
      final List<FakeCutPlanSource> unmatched =
          await FakeCutDiscovery.scanUnmatched(
        videoPath: file.uri,
        sourceDurationMs: file.durationMs,
      );
      sources = <FakeCutPlanSource>[...own, ...unmatched];
    } catch (e) {
      _log.w('fake cut discover failed: ${file.uri}: $e');
      sources = const <FakeCutPlanSource>[];
    }
    set(state.copyWith(
      plansByFile: <String, List<FakeCutPlanSource>>{
        ...state.plansByFile,
        key: sources,
      },
      discovering: <String, bool>{...state.discovering, key: false},
      scannedDurationMs: <String, int>{...state.scannedDurationMs, key: probedMs},
    ));
    // Drain a request that arrived mid-scan. It is awaited so `await discover`
    // means "this file's list matches the duration the caller knows".
    final _PendingScan? pending = _pending.remove(key);
    if (pending != null &&
        (pending.force || (pending.file.durationMs ?? 0) > probedMs)) {
      await discover(pending.file, force: pending.force);
    }
  }

  /// Makes [source] the plan this window plays [file] with.
  ///
  /// Returns false when the project has no playable range (the tab then explains
  /// it instead of reopening the media onto an empty timeline).
  Future<bool> activate(FileItem file, FakeCutPlanSource source) async {
    final project = source.project;
    // A project that belongs to ANOTHER video (or to a source that no longer
    // exists) must never be applied here: the EDL is built over the PLAYING
    // file, so it would play this video with another file's cut ranges.
    if (project == null || !source.bound) return false;
    final String key = fakeCutFileKey(file);
    // Rebuild against the duration known NOW: discovery may have run before the
    // container was probed, and clamping past-the-end ranges needs it.
    final FakeCutPlan plan = buildFakeCutPlan(
      planPath: source.path,
      project: project,
      sourceFileName: p.basename(file.uri),
      sourceDurationMs: file.durationMs,
    );
    if (plan.isEmpty) return false;
    set(state.copyWith(
      revision: state.revision + 1,
      activePaths: <String, String>{...state.activePaths, key: source.path},
      activePlans: <String, FakeCutPlan>{...state.activePlans, key: plan},
      activePlanSignatures: <String, String>{
        ...state.activePlanSignatures,
        key: source.signature,
      },
    ));
    await _persistActivePaths();
    _log.i('fake cut activated: ${file.name} <- ${source.displayName} '
        '(${plan.segments.length} segments)');
    return true;
  }

  /// Stops playing the cut and goes back to the untouched source.
  Future<void> deactivate(FileItem file) async {
    final String key = fakeCutFileKey(file);
    if (!state.activePaths.containsKey(key)) return;
    final Map<String, String> paths = <String, String>{...state.activePaths}
      ..remove(key);
    final Map<String, FakeCutPlan> plans = <String, FakeCutPlan>{
      ...state.activePlans
    }..remove(key);
    set(state.copyWith(
      revision: state.revision + 1,
      activePaths: paths,
      activePlans: plans,
    ));
    await _persistActivePaths();
    _log.i('fake cut deactivated: ${file.name}');
  }

  /// The plan [file] should open with RIGHT NOW, or null for the plain source.
  ///
  /// Called by the player `init` BEFORE opening, so a remembered plan costs one
  /// open (not a source open followed by an EDL reopen). It never bumps
  /// [FakeCutStoreState.revision]: materialization is not a user switch.
  ///
  /// The materialized plan is a CACHE of the `.llc`, not a copy of it: editing
  /// the project must show up on the next open, so a matching path alone is not
  /// enough — the source's `mtime:size` has to match the one the plan was built
  /// from too (otherwise the old timeline replayed forever).
  Future<FakeCutPlan?> ensureActivePlan(FileItem file) async {
    final String key = fakeCutFileKey(file);
    final String? path = state.activePaths[key];
    if (path == null) return null;
    final FakeCutPlan? cached = state.activePlans[key];
    if (cached != null && cached.planPath == path) {
      final String? current = await FakeCutDiscovery.signatureOf(path);
      if (current != null && current == state.activePlanSignatures[key]) {
        return cached;
      }
      _log.i('fake cut: project changed on disk, re-reading $path');
    }

    final FakeCutPlanSource? source;
    try {
      source = await FakeCutDiscovery.readOne(
        File(path),
        sourceFileName: p.basename(file.uri),
        sourceDurationMs: file.durationMs,
      );
    } catch (e) {
      // `readOne` is total by contract; this is the last line of defence for
      // the OPEN: throwing here aborted `init` (the media never opened and the
      // previous file's session stayed attached to this one).
      _log.w('fake cut: remembered plan unreadable, dropping: $path: $e');
      await _forgetPlan(key);
      return null;
    }
    final project = source?.project;
    if (project == null) {
      // The project vanished or became unreadable: forget it instead of failing
      // the open. The media simply plays as the untouched source.
      _log.w('fake cut: remembered plan unusable, dropping: $path');
      await _forgetPlan(key);
      return null;
    }
    final FakeCutPlan plan = buildFakeCutPlan(
      planPath: path,
      project: project,
      sourceFileName: p.basename(file.uri),
      sourceDurationMs: file.durationMs,
    );
    if (plan.isEmpty) {
      await _forgetPlan(key);
      return null;
    }
    set(state.copyWith(
      activePlans: <String, FakeCutPlan>{...state.activePlans, key: plan},
      activePlanSignatures: <String, String>{
        ...state.activePlanSignatures,
        key: source!.signature,
      },
    ));
    return plan;
  }

  Future<void> _forgetPlan(String key) async {
    final Map<String, String> paths = <String, String>{...state.activePaths}
      ..remove(key);
    final Map<String, FakeCutPlan> plans = <String, FakeCutPlan>{
      ...state.activePlans
    }..remove(key);
    final Map<String, String> signatures = <String, String>{
      ...state.activePlanSignatures
    }..remove(key);
    set(state.copyWith(
      activePaths: paths,
      activePlans: plans,
      activePlanSignatures: signatures,
    ));
    await _persistActivePaths();
  }
}

/// One `discover()` call that had to wait for an in-flight scan.
class _PendingScan {
  const _PendingScan({required this.file, required this.force});

  final FileItem file;
  final bool force;
}

FakeCutStore useFakeCutStore() => create(() => FakeCutStore());
