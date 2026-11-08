import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';
import 'package:iris/utils/logger.dart';
import 'package:path/path.dart' as p;

final _log = AreaKeyLog(LogKeys.legacyPlayer);

/// mpv detects an EDL by this exact first line (`demux_edl.c: HEADER`).
const String kFakeCutEdlHeader = '# mpv EDL v0\n';

/// One temporary `.edl` = one plan + the source it was built for.
///
/// The plan itself is a few hundred bytes: it references the video by path and
/// never copies, transcodes or pre-reads it. A 10 GB source therefore produces
/// the same ~1 KB file as a 10 MB one.
class FakeCutEdlFile {
  const FakeCutEdlFile({required this.path, required this.sourcePath});

  /// Absolute path of the generated `.edl` (what media_kit opens).
  final String path;

  /// The source file the EDL references (for logging/diagnostics).
  final String sourcePath;
}

/// Normalizes a local absolute path for use inside an EDL part.
///
/// mpv's `fix_filenames` leaves an ABSOLUTE path alone (`mp_path_join` returns
/// it verbatim), so the EDL never needs a `file://` prefix — and avoiding the
/// scheme means `open_source()`'s same-filename demuxer reuse compares the very
/// same string on every part.
String fakeCutEdlSourcePath(String localPath) => localPath.replaceAll('\\', '/');

/// Builds the EDL text.
///
/// Layout: the header, `!no_chapters` (source chapters would otherwise be
/// remapped onto cut ranges and show up as misleading chapter marks), then one
/// part per segment in plan order.
///
/// Every parameter value is `%N%`-escaped, where N is the payload's BYTE length
/// (`demux_edl.c` parses `%`, an integer, `%`, then N raw bytes). Escaping is
/// mandatory: an unescaped value stops at the first `,`/`;`/newline, so a
/// Chinese, comma-bearing or `%`-bearing path would silently split the part.
String buildFakeCutEdlText({
  required FakeCutPlan plan,
  required String sourcePath,
}) {
  final String reference = fakeCutEdlSourcePath(sourcePath);
  final StringBuffer out = StringBuffer()
    ..write(kFakeCutEdlHeader)
    ..write('!no_chapters\n');
  for (final FakeCutSegment segment in plan.segments) {
    out
      ..write(_edlParam(reference))
      ..write(',start=')
      ..write(_edlSeconds(segment.startMs))
      ..write(',length=')
      ..write(_edlSeconds(segment.durationMs))
      ..write('\n');
  }
  return out.toString();
}

String _edlSeconds(int milliseconds) =>
    (milliseconds / 1000).toStringAsFixed(3);

String _edlParam(String payload) {
  // BYTE length, not rune count: mpv splices the raw bytes back out.
  final int byteLength = utf8.encode(payload).length;
  return '%$byteLength%$payload';
}

/// Stable, dependency-free content hash for cache file names.
///
/// Two independent 32-bit FNV-1a rounds (different offset basis) are joined so
/// the key is 16 hex chars. Arithmetic stays inside Dart's 53-bit-safe range, so
/// it behaves identically on the VM and when compiled to JavaScript.
String fakeCutCacheKey(String input) => fakeCutCacheKeyOfBytes(utf8.encode(input));

/// [fakeCutCacheKey] over raw bytes.
///
/// Cache keys that describe a FILE must hash its CONTENT, not its length: a
/// subtitle edit that keeps the same size (the usual case — only digits/timing
/// text change) reused the stale artefact.
String fakeCutCacheKeyOfBytes(List<int> bytes) {
  int round(int basis) {
    int hash = basis;
    for (final int byte in bytes) {
      hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  final String a = round(0x811c9dc5).toRadixString(16).padLeft(8, '0');
  final String b = round(0x01000193).toRadixString(16).padLeft(8, '0');
  return '$a$b';
}

/// Directory under the app temp root that holds every generated artefact
/// (EDL + remapped subtitles). Kept out of the user's media folders on purpose:
/// 简播 must never write next to the source.
Directory fakeCutCacheDirectory(Directory tempRoot) =>
    Directory(p.join(tempRoot.path, 'iris_fake_cut'));

/// Writes (or reuses) the `.edl` for [plan] + [sourcePath].
///
/// [signature] must change whenever the plan's CONTENT changes — both callers
/// pass [fakeCutPlanSignature] (the range list itself), and the key ALSO embeds
/// it, so an edited project can never reuse a stale timeline even when its
/// mtime/size are unchanged.
Future<FakeCutEdlFile> prepareFakeCutEdl({
  required FakeCutPlan plan,
  required String sourcePath,
  required String signature,
  required Directory tempRoot,
}) async {
  final Directory cacheDir = fakeCutCacheDirectory(tempRoot);
  if (!await cacheDir.exists()) {
    await cacheDir.create(recursive: true);
  }
  final String key = fakeCutCacheKey(
      '${plan.planPath}\u0000$signature\u0000$sourcePath\u0000'
      '${fakeCutPlanSignature(plan)}');
  final String name = '${_safeFileStem(plan.displayName)}.$key.edl';
  final File file = File(p.join(cacheDir.path, name));
  if (!await file.exists()) {
    await file.writeAsString(
      buildFakeCutEdlText(plan: plan, sourcePath: sourcePath),
      encoding: utf8,
      flush: true,
    );
  }
  unawaitedPrune(cacheDir, keep: file.path);
  _log.i('fake cut EDL ready: $name (${plan.segments.length} segments)');
  return FakeCutEdlFile(path: file.path, sourcePath: sourcePath);
}

/// Content signature of the plan's ranges. Changes whenever a segment's bounds
/// change, which is what invalidates every generated artefact (EDL + remapped
/// subtitles) for this plan.
String fakeCutPlanSignature(FakeCutPlan plan) {
  final StringBuffer out = StringBuffer();
  for (final FakeCutSegment segment in plan.segments) {
    out
      ..write(segment.startMs)
      ..write(':')
      ..write(segment.endMs)
      ..write(',');
  }
  return out.toString();
}

/// Keeps a file-system-safe stem for the cache name (the raw display name may
/// contain separators, `:` or emoji that Windows rejects).
///
/// Capped at 32 characters so `<temp>/iris_fake_cut/<stem>.<hash>.edl` stays far
/// below the legacy 260-character Windows path limit even for a deep temp root.
String _safeFileStem(String raw) {
  final String cleaned =
      raw.replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001F]'), '_').trim();
  if (cleaned.isEmpty) return 'plan';
  return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
}

/// Relative age after which a cache artefact is considered abandoned. Editing a
/// project produces a NEW key, so old EDLs are unreachable immediately; the
/// window only keeps a re-opened plan's file warm.
const Duration kFakeCutCacheTtl = Duration(days: 7);

/// Best-effort pruning so the temp folder cannot grow without bound.
Future<void> pruneFakeCutCache(Directory cacheDir,
    {String? keep, DateTime? now}) async {
  final DateTime reference = now ?? DateTime.now();
  try {
    if (!await cacheDir.exists()) return;
    await for (final FileSystemEntity entity in cacheDir.list()) {
      if (entity is! File) continue;
      if (keep != null && p.equals(entity.path, keep)) continue;
      final DateTime modified = await entity.lastModified();
      if (reference.difference(modified) > kFakeCutCacheTtl) {
        await entity.delete();
      }
    }
  } catch (e) {
    _log.w('fake cut cache prune failed: $e');
  }
}

/// Fire-and-forget wrapper so EDL preparation never waits on maintenance.
void unawaitedPrune(Directory cacheDir, {String? keep}) {
  // Deliberately not awaited: a slow temp dir must not delay the open.
  unawaited(pruneFakeCutCache(cacheDir, keep: keep));
}
