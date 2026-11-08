import 'dart:convert';
import 'dart:io';

import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/services/fake_cut_pairing.dart';
import 'package:iris/features/fake_cut/services/fake_cut_plan_builder.dart';
import 'package:iris/features/fake_cut/services/fake_cut_project_index.dart';
import 'package:iris/features/fake_cut/services/llc_parser.dart';
import 'package:iris/utils/logger.dart';
import 'package:path/path.dart' as p;

final _log = AreaKeyLog(LogKeys.legacyPlayer);

/// A `.llc` found next to the playing video, already parsed into a plan.
///
/// Parsing at discovery time (instead of on tap) is what lets the tab show the
/// segment count, the cut length and the "this project was made for another
/// file" warning BEFORE the user switches playback.
class FakeCutPlanSource {
  const FakeCutPlanSource({
    required this.path,
    required this.size,
    required this.modifiedMs,
    this.project,
    this.plan,
    this.parseFailure,
    this.parseDetail,
    this.bound = true,
  });

  final String path;
  final int size;
  final int modifiedMs;

  /// The parsed project, kept so activation can rebuild the plan against the
  /// source duration CURRENTLY known (discovery may have run before the
  /// container duration was probed).
  final LlcProject? project;

  /// Null when [parseFailure] is set (or the plan has no playable segment).
  final FakeCutPlan? plan;

  final LlcParseFailure? parseFailure;
  final String? parseDetail;

  /// Whether this project was BOUND to the playing video by
  /// [FakeCutProjectIndex].
  ///
  /// An unmatched project (no video in the folder owns it — usually the source
  /// was renamed or moved) is listed in the tab's collapsed 「无匹配计划」
  /// section and can NEVER be activated: the EDL is built over the PLAYING file,
  /// so applying another file's ranges is exactly the bug where two projects
  /// both played the one video on screen.
  final bool bound;

  String get displayName => p.basenameWithoutExtension(path);

  /// Cache/identity signature: an edit changes mtime and/or size.
  String get signature => '$modifiedMs:$size';

  bool get usable => plan != null && plan!.segments.isNotEmpty;
}

/// Finds and parses the LosslessCut projects that belong to one video.
///
/// v1 SCOPE: local file system only. SAF (`content://`), WebDAV and FTP entries
/// have no readable sibling directory through this path, so the tab simply finds
/// nothing there (and the preflight marks the feature unavailable) instead of
/// offering a broken plan list.
abstract final class FakeCutDiscovery {
  /// Refuse absurdly large "project" files: a real `.llc` is a few KB, and a
  /// multi-megabyte JSON is far more likely to be a mis-extension than a plan.
  static const int maxProjectBytes = 4 * 1024 * 1024;

  /// The projects that belong to [videoPath] — its own 简播 plans, in the same
  /// default (file-name) order its sibling subtitles are listed in.
  ///
  /// A video owns ZERO..N projects: `movie.llc` and `movie.cut2.llc` are two
  /// plans for the same file, exactly like two `.ass`/`.srt` siblings.
  static Future<List<FakeCutPlanSource>> scan({
    required String videoPath,
    int? sourceDurationMs,
  }) =>
      _readAll(
        FakeCutProjectIndex.instance.projectsForVideo(videoPath),
        videoPath: videoPath,
        sourceDurationMs: sourceDurationMs,
        bound: true,
      );

  /// The projects in [videoPath]'s directory that belong to NO video there.
  ///
  /// Surfaced (never applied) so a renamed source is not silently lost: the tab
  /// shows them in its collapsed 「无匹配计划」 section with the recorded name.
  static Future<List<FakeCutPlanSource>> scanUnmatched({
    required String videoPath,
    int? sourceDurationMs,
  }) =>
      _readAll(
        FakeCutProjectIndex.instance.unmatchedProjectsFor(videoPath),
        videoPath: videoPath,
        sourceDurationMs: sourceDurationMs,
        bound: false,
      );

  static Future<List<FakeCutPlanSource>> _readAll(
    Future<List<LlcSibling>> siblings, {
    required String videoPath,
    required int? sourceDurationMs,
    required bool bound,
  }) async {
    final String sourceFileName = p.basename(videoPath);
    if (sourceFileName.isEmpty) return const <FakeCutPlanSource>[];
    final List<LlcSibling> projects;
    try {
      projects = await siblings;
    } catch (e) {
      // A failed listing is an empty answer, never an exception: the playing
      // file must keep working.
      _log.w('fake cut discovery failed for $videoPath: $e');
      return const <FakeCutPlanSource>[];
    }
    final List<FakeCutPlanSource> found = <FakeCutPlanSource>[];
    for (final LlcSibling project in projects) {
      final FakeCutPlanSource? source = await readOne(
        File(project.path),
        sourceFileName: sourceFileName,
        sourceDurationMs: sourceDurationMs,
        bound: bound,
      );
      if (source != null) found.add(source);
    }
    return List<FakeCutPlanSource>.unmodifiable(found);
  }

  /// `mtime:size` of ONE project file — the same signature
  /// [FakeCutPlanSource.signature] carries, without parsing it.
  ///
  /// `FakeCutStore.ensureActivePlan` uses it to notice an EDITED project (a
  /// matching path alone is not enough, or the last-parsed timeline would
  /// replay forever). A project that cannot be stat'ed returns null: the caller
  /// then re-reads it, which is where the missing/unreadable verdict belongs.
  static Future<String?> signatureOf(String projectPath) async {
    try {
      final FileStat stat = await File(projectPath).stat();
      return '${stat.modified.millisecondsSinceEpoch}:${stat.size}';
    } catch (_) {
      return null;
    }
  }

  /// Reads + parses ONE project file. Public so the player hook can materialize
  /// a persisted active plan without rescanning the directory.
  static Future<FakeCutPlanSource?> readOne(
    File file, {
    required String sourceFileName,
    int? sourceDurationMs,
    bool bound = true,
  }) async {
    final int size;
    final int modifiedMs;
    try {
      final FileStat stat = await file.stat();
      size = stat.size;
      modifiedMs = stat.modified.millisecondsSinceEpoch;
    } catch (e) {
      _log.w('fake cut stat failed: ${file.path}: $e');
      return null;
    }
    if (size <= 0 || size > maxProjectBytes) {
      return FakeCutPlanSource(
        path: file.path,
        size: size,
        modifiedMs: modifiedMs,
        parseFailure: LlcParseFailure.invalidStructure,
        parseDetail: 'implausible project size: $size bytes',
        bound: bound,
      );
    }

    final String raw;
    try {
      final List<int> bytes = await file.readAsBytes();
      raw = utf8.decode(bytes, allowMalformed: false);
    } catch (e) {
      _log.w('fake cut read failed: ${file.path}: $e');
      return FakeCutPlanSource(
        path: file.path,
        size: size,
        modifiedMs: modifiedMs,
        parseFailure: LlcParseFailure.invalidJson,
        parseDetail: 'not valid UTF-8: $e',
        bound: bound,
      );
    }

    try {
      final LlcProject project = LlcParser.parse(raw);
      final FakeCutPlan plan = buildFakeCutPlan(
        planPath: file.path,
        project: project,
        sourceFileName: sourceFileName,
        sourceDurationMs: sourceDurationMs,
      );
      return FakeCutPlanSource(
        path: file.path,
        size: size,
        modifiedMs: modifiedMs,
        project: project,
        plan: plan,
        bound: bound,
      );
    } on LlcParseException catch (e) {
      _log.w('fake cut parse failed: ${file.path}: $e');
      return FakeCutPlanSource(
        path: file.path,
        size: size,
        modifiedMs: modifiedMs,
        parseFailure: e.failure,
        parseDetail: e.detail,
        bound: bound,
      );
    } catch (e) {
      // TOTAL by contract: the parser reports corruption as `LlcParseException`,
      // but this call must also survive anything else it can raise (an escaped
      // FormatException, an Error from a pathological project). The scan loop
      // has no per-file try, so a throw here would empty the WHOLE folder's
      // list, and `ensureActivePlan` would abort the open with it.
      _log.w('fake cut project crashed the reader: ${file.path}: $e');
      return FakeCutPlanSource(
        path: file.path,
        size: size,
        modifiedMs: modifiedMs,
        parseFailure: LlcParseFailure.invalidJson,
        parseDetail: '$e',
        bound: bound,
      );
    }
  }
}
