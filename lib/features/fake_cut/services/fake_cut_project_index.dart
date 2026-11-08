import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:iris/features/fake_cut/core/fake_cut_preflight.dart';
import 'package:iris/features/fake_cut/services/fake_cut_discovery.dart';
import 'package:iris/features/fake_cut/services/fake_cut_pairing.dart';
import 'package:iris/features/fake_cut/services/llc_parser.dart';
import 'package:iris/utils/check_content_type.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/natural_sort_key.dart';
import 'package:path/path.dart' as p;

final _log = AreaKeyLog(LogKeys.legacyPlayer);

/// One media to test for a sibling `.llc`, in the form the VM group pipeline
/// already has: its canonical media key plus what pairing needs.
typedef FakeCutProjectQuery = ({String mediaKey, String name, String uri});

/// A directory's cut projects, reduced to what PAIRING needs.
///
/// Only names are kept — the plans themselves are parsed by [FakeCutDiscovery]
/// when a video is actually played, so this index stays cheap even for a folder
/// that holds a project per episode.
class FakeCutDirProjects {
  const FakeCutDirProjects({
    this.videoNames = const <String>[],
    this.projects = const <LlcSibling>[],
    this.unparseableCount = 0,
  });

  /// File names of the videos in this directory.
  ///
  /// Needed for the ambiguous cases: a project may only bind to the video it
  /// actually extends, which is a fact about the whole directory, not about one
  /// queried file.
  final List<String> videoNames;

  /// Every `.llc` found here, already read for its `mediaFileName`.
  final List<LlcSibling> projects;

  /// Projects that exist but produced no usable name (diagnostics only).
  final int unparseableCount;

  bool get isEmpty => projects.isEmpty;

  LlcBinding bind({required String videoName}) => bindLlcProjects(
        videoNames: <String>{...videoNames, videoName},
        projects: projects,
      );
}

/// Per-directory index of "which `.llc` belongs to which video".
///
/// WHY an index instead of a per-resolve listing: Virtual Media grouping runs
/// over the whole view (hundreds of files) on every list materialization, the
/// 简播 tab rescans on open, and the answer is a property of the FILESYSTEM, not
/// of the media row. Listing a directory once and remembering its projects —
/// with the `mediaFileName` each one recorded — makes every later question
/// (does THIS video have a project? which ones?) pure in-memory work.
///
/// Freshness is EXPLICIT by design: a `.llc` created after a group was built
/// only counts after [invalidate] (the 简播 tab's refresh button calls it) — the
/// user accepted "新建简播后需刷新" as the contract, and a silent TTL would make
/// the group set change under the user's feet.
class FakeCutProjectIndex {
  FakeCutProjectIndex();

  static FakeCutProjectIndex? _instance;

  static FakeCutProjectIndex get instance =>
      _instance ??= FakeCutProjectIndex();

  /// Per-directory result cache. A Future is cached (not the value) so two
  /// concurrent resolves share one listing instead of racing. A FAILED listing
  /// is removed again (see [_dirProjects]): the cache may only hold answers.
  final Map<String, Future<FakeCutDirProjects>> _dirs =
      <String, Future<FakeCutDirProjects>>{};

  /// Test seam: a failing directory listing (an unready drive, a permission
  /// blip) cannot be produced portably, and "not cached" is the contract under
  /// test. Null (production) reads the real filesystem.
  @visibleForTesting
  static Future<FakeCutDirProjects> Function(String dirPath)?
      debugReadDirectory;

  /// Drops the cached listings — all of them, or one directory.
  ///
  /// Call after anything that can add/remove a `.llc`: the 简播 tab's refresh,
  /// a media rescan, or an explicit "重新分组" from the VM side.
  void invalidate([String? directoryPath]) {
    if (directoryPath == null) {
      _dirs.clear();
      return;
    }
    _dirs.remove(_dirKey(directoryPath));
  }

  /// The projects that belong to the video at [videoPath] — its own 简播 plans.
  ///
  /// Empty when the file is not a plain local path (SAF/remote siblings are not
  /// readable through this path) or lives in no directory.
  Future<List<LlcSibling>> projectsForVideo(String videoPath) async {
    final String name = p.basename(videoPath);
    if (name.isEmpty) return const <LlcSibling>[];
    final FakeCutDirProjects dir = await _dirFor(videoPath);
    if (dir.isEmpty) return const <LlcSibling>[];
    return dir.bind(videoName: name).forVideo(name);
  }

  /// The projects in [videoPath]'s directory that belong to NO video there.
  ///
  /// Renamed/moved sources land here; they are shown in the tab's collapsed
  /// 「无匹配计划」 section and can never be activated for a video they do not
  /// describe.
  Future<List<LlcSibling>> unmatchedProjectsFor(String videoPath) async {
    final String name = p.basename(videoPath);
    if (name.isEmpty) return const <LlcSibling>[];
    final FakeCutDirProjects dir = await _dirFor(videoPath);
    if (dir.isEmpty) return const <LlcSibling>[];
    return dir.bind(videoName: name).unmatched;
  }

  /// Media keys (same canonical form VM uses) whose video owns a project.
  ///
  /// Non-local entries (SAF / WebDAV / FTP) never match: their siblings are not
  /// readable through this path, and 简播 itself is unavailable there.
  Future<Set<String>> mediaKeysWithProject(
    Iterable<FakeCutProjectQuery> files,
  ) async {
    final Map<String, List<FakeCutProjectQuery>> byDir =
        <String, List<FakeCutProjectQuery>>{};
    for (final FakeCutProjectQuery file in files) {
      if (!FakeCutPreflight.isLocalFilePath(file.uri)) continue;
      final String dir = p.dirname(file.uri);
      if (dir.isEmpty || dir == '.') continue;
      (byDir[_dirKey(dir)] ??= <FakeCutProjectQuery>[]).add(file);
    }
    if (byDir.isEmpty) return const <String>{};

    // Distinct directories are listed CONCURRENTLY: a whole-library pass (the
    // VM manager preview) can span hundreds of folders, and one sequential
    // listing per folder is the only part of this that can be slow.
    final List<String> dirs = byDir.keys.toList(growable: false);
    final List<FakeCutDirProjects> loaded = await Future.wait(
      dirs.map(_dirProjects),
    );

    final Set<String> matched = <String>{};
    for (int i = 0; i < dirs.length; i++) {
      final FakeCutDirProjects projects = loaded[i];
      if (projects.isEmpty) continue;
      final List<FakeCutProjectQuery> queries = byDir[dirs[i]]!;
      // ONE binding per directory, not per file: a whole-library pass queries
      // every video of a folder, and pairing is a per-directory computation.
      final LlcBinding binding = bindLlcProjects(
        videoNames: <String>{
          ...projects.videoNames,
          for (final FakeCutProjectQuery query in queries) _queryName(query),
        }.where((String name) => name.isNotEmpty),
        projects: projects.projects,
      );
      for (final FakeCutProjectQuery query in queries) {
        final String name = _queryName(query);
        if (name.isEmpty) continue;
        if (binding.forVideo(name).isNotEmpty) matched.add(query.mediaKey);
      }
    }
    return matched;
  }

  static String _queryName(FakeCutProjectQuery query) =>
      query.name.isNotEmpty ? query.name : p.basename(query.uri);

  /// Whether ONE video owns a project (the 简播 tab / player side).
  Future<bool> hasProjectFor(FakeCutProjectQuery file) async =>
      (await mediaKeysWithProject(<FakeCutProjectQuery>[file]))
          .contains(file.mediaKey);

  Future<FakeCutDirProjects> _dirFor(String videoPath) {
    final String dir = p.dirname(videoPath);
    if (dir.isEmpty || dir == '.') {
      return Future<FakeCutDirProjects>.value(const FakeCutDirProjects());
    }
    return _dirProjects(_dirKey(dir));
  }

  Future<FakeCutDirProjects> _dirProjects(String dirPath) {
    final Future<FakeCutDirProjects>? cached = _dirs[dirPath];
    if (cached != null) return cached;
    final Completer<FakeCutDirProjects> completer =
        Completer<FakeCutDirProjects>();
    _dirs[dirPath] = completer.future;
    (debugReadDirectory ?? _readDirectory)(dirPath).then(
      completer.complete,
      onError: (Object e, StackTrace st) {
        // A FAILED listing is not an answer: caching it as "this folder has no
        // projects" disabled 简播 for the folder until an explicit invalidate
        // (one transient IO error — an unready drive, a permission blip — was
        // enough). Drop the entry so the next resolve retries; the caller still
        // gets a usable empty answer for THIS pass.
        if (identical(_dirs[dirPath], completer.future)) {
          _dirs.remove(dirPath);
        }
        _log.w('fake cut project index failed for $dirPath: $e');
        completer.complete(const FakeCutDirProjects());
      },
    );
    return completer.future;
  }

  static String _dirKey(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;

  static Future<FakeCutDirProjects> _readDirectory(String dirPath) async {
    final List<String> videos = <String>[];
    final List<LlcSibling> projects = <LlcSibling>[];
    int unparseable = 0;
    try {
      final Directory dir = Directory(dirPath);
      if (!await dir.exists()) return const FakeCutDirProjects();
      await for (final FileSystemEntity entity in dir.list()) {
        if (entity is! File) continue;
        final String name = p.basename(entity.path);
        if (p.extension(name).toLowerCase() != '.llc') {
          if (isVideoFile(name)) videos.add(name);
          continue;
        }
        final String? mediaFileName = await _readMediaFileName(entity);
        if (mediaFileName == null) unparseable++;
        projects.add(
          LlcSibling(path: entity.path, mediaFileName: mediaFileName),
        );
      }
    } catch (e) {
      // A directory we cannot list is NOT "no projects": rethrow so the caller
      // (see [_dirProjects]) drops the cache entry and retries next resolve,
      // while grouping still gets an empty answer for this pass.
      _log.w('fake cut project index failed for $dirPath: $e');
      rethrow;
    }
    // Stable, deterministic order (NTFS itself lists names in this order): the
    // tab shows a video's projects in it, exactly like its subtitle list.
    projects.sort((LlcSibling a, LlcSibling b) =>
        naturalCompare(a.fileName, b.fileName));
    if (projects.isNotEmpty) {
      _log.d('fake cut project index $dirPath: '
          '${projects.length} projects, ${videos.length} videos');
    }
    return FakeCutDirProjects(
      videoNames: videos,
      projects: projects,
      unparseableCount: unparseable,
    );
  }

  /// Reads only the recorded source name; null when the project is unreadable,
  /// too large to be a project, or has no `mediaFileName`.
  static Future<String?> _readMediaFileName(File file) async {
    try {
      final FileStat stat = await file.stat();
      if (stat.size <= 0 || stat.size > FakeCutDiscovery.maxProjectBytes) {
        return null;
      }
      final List<int> bytes = await file.readAsBytes();
      final LlcProject project =
          LlcParser.parse(utf8.decode(bytes, allowMalformed: false));
      final String? name = project.mediaFileName;
      return name == null || name.isEmpty ? null : name;
    } catch (e) {
      // Unparseable is expected (hand-edited files, future versions): the stem
      // fallback still pairs it, so this is a log line, not a failure.
      _log.d('fake cut project name unreadable: ${file.path}: $e');
      return null;
    }
  }
}
