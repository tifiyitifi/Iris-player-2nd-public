import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:iris/features/playback_tools/services/screenshot_media_scan.dart';
import 'package:iris/features/video_transform/services/video_transform_math.dart';
import 'package:iris/features/video_transform/store/video_transform_store.dart';
import 'package:iris/features/playback_tools/services/screenshot_paths.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/app_paths.dart';
import 'package:iris/utils/platform.dart'
    show isAndroid, isLinux, isMacOS, isMobilePlatform, isWindows;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:iris/models/player.dart';
import 'package:iris/utils/request_storage_permission.dart';
import 'package:iris/utils/path_conv.dart' show isSafPath;

final Logger _log = Logger('playback_tools.screenshot');

/// Pure target-path rule shared by the keyboard scheme and the phone float
/// panel: every capture lands in ONE predictable directory — the custom dir
/// when set, otherwise the platform default (Android public
/// `Pictures/IRIS Screenshots`, portable `<root>/screenshots`, installed
/// `<pictures>/IRIS`). The file keeps the playing video's stem
/// (`<stem>_yyyyMMdd_HHmmss_SSS.png`) or the `iris_` prefix for remote sources.
///
/// The date + millisecond stamp replaces the old `HHmmss`-only name: a bare
/// clock stamp silently overwrote earlier shots taken at the same wall-clock
/// time on another day (and same-second bursts).
///
/// The old beside-video rule is gone on purpose: video-adjacent dirs are
/// often read-only (scoped storage, removable media, network mounts), and a
/// scattered layout is undiscoverable next to a gallery-visible folder.
String resolveScreenshotTargetPath({
  required String? localVideoPath,
  required String customDirPath,
  required String defaultDirPath,
  required DateTime now,
}) {
  final String base;
  if (localVideoPath != null) {
    final name = p.basename(localVideoPath);
    final dot = name.lastIndexOf('.');
    base = dot > 0 ? name.substring(0, dot) : name;
  } else {
    base = 'iris';
  }
  final String dirPath =
      resolveScreenshotDirName(customDir: customDirPath, defaultDir: defaultDirPath);
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  final String stamp = '${now.year}${two(now.month)}${two(now.day)}'
      '_${two(now.hour)}${two(now.minute)}${two(now.second)}'
      '_${three(now.millisecond)}';
  return p.join(dirPath, '${base}_$stamp.png');
}

/// Outcome of one frame-capture attempt; callers render it as user feedback
/// (see screenshot_feedback.dart). A capture used to return null on EVERY
/// failure — silently, with zero feedback — which made the phone shutter look
/// completely broken; the typed result names the outcome instead.
sealed class ScreenshotResult {
  const ScreenshotResult();
}

/// Frame captured and written to [path] (which may be the documents
/// fallback when the beside-video write was denied by scoped storage).
class ScreenshotSuccess extends ScreenshotResult {
  const ScreenshotSuccess(this.path, {this.customDirSkipped = false});

  final String path;

  /// True when the user's custom directory was rejected (mapped but not
  /// writable, e.g. no Android All-files access) and the capture fell back to
  /// the default directory. Callers surface this so the silent fallback is
  /// visible instead of looking like the custom dir was honored.
  final bool customDirSkipped;
}

/// The active backend cannot capture frames at all (fvp: no screenshot
/// capability). Callers offer the MediaKit switch instead of a retry.
class ScreenshotUnsupported extends ScreenshotResult {
  const ScreenshotUnsupported(this.backend);

  final String backend;
}

/// Why a capture or write failed. The presentation layer maps each kind to a
/// localized message (see `screenshotFailureMessage`); the service never
/// carries user-facing text, only the machine-readable [ScreenshotFailureKind]
/// plus an optional raw [ScreenshotFailure.detail] for diagnostics.
enum ScreenshotFailureKind {
  /// The backend threw while grabbing the raw frame.
  frameGrab,

  /// The backend returned no (or empty) frame bytes.
  emptyFrame,

  /// Non-PNG frame bytes could not be decoded/re-encoded as PNG.
  undecodable,

  /// Every path in the write chain failed.
  write,

  /// The platform save directory could not be resolved.
  noDir,

  /// The capture exceeded the hard timeout.
  timeout,

  /// An unexpected error escaped the capture pipeline.
  unknown,
}

/// Capture or write failed for a stated reason (empty frame, IO error, ...).
class ScreenshotFailure extends ScreenshotResult {
  const ScreenshotFailure(this.kind, {this.detail});

  final ScreenshotFailureKind kind;

  /// Raw diagnostic text (an exception's message); never shown verbatim on its
  /// own — it is interpolated into the localized message for [kind].
  final String? detail;
}

/// Raw frame source (media_kit `player.screenshot` in production).
typedef FrameSource = Future<Uint8List?> Function();

/// Persists the PNG bytes; production writes the real file, tests record.
typedef FrameWriter = Future<void> Function(String path, Uint8List bytes);

/// Creates a directory (recursively); production hits the filesystem.
typedef DirEnsurer = Future<void> Function(String dir);

/// Re-encodes arbitrary frame bytes as PNG; null when undecodable.
typedef PngTranscoder = Future<Uint8List?> Function(Uint8List bytes);

/// Applies the live-surface geometric transform (mirror/rotation) to captured
/// PNG bytes; null means "keep the original bytes".
typedef PngPostProcessor = Future<Uint8List?> Function(Uint8List bytes);

/// Tells the OS gallery about a saved file; production scans on Android.
typedef GalleryNotifier = Future<void> Function(String path);

/// True when [bytes] start with the PNG magic (`89 50 4E 47`).
///
/// media_kit honors `format: 'image/png'` inconsistently across platforms —
/// Android mpv may hand back JPEG bytes instead. Writing those under a
/// `.png` name produces files strict decoders (gallery apps, upload sheets)
/// reject, so every frame is sniffed before it touches the disk.
bool isPngBytes(Uint8List bytes) =>
    bytes.length > 4 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

/// Production [PngTranscoder]: pure-Dart decode + PNG re-encode via the
/// already-depended `image` package. The capture core runs this through
/// `compute`, so the decode/encode cost stays off the UI isolate.
Future<Uint8List?> transcodeToPngBytes(Uint8List bytes) async {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;
  return Uint8List.fromList(img.encodePng(decoded));
}

/// Testable capture core with every production dependency injected.
///
/// Pipeline: capability gate → raw frame → PNG guarantee (magic sniff,
/// transcode anything non-PNG) → target path (custom dir, platform
/// default, documents last resort) → async write with per-level fallback
/// so a revoked permission or a pulled drive degrades instead of losing
/// the shot → gallery notification so the file is visible to other apps.
Future<ScreenshotResult> captureFrameCore({
  required bool isMediaKit,
  required FrameSource frameSource,
  required String? Function() resolveLocalVideoPath,
  required String customDirPath,
  required String defaultDirPath,
  required String documentsDirPath,
  required DateTime now,
  required FrameWriter writeBytes,
  DirEnsurer? ensureDir,
  PngTranscoder? transcodeToPng,
  PngPostProcessor? postProcessPng,
  GalleryNotifier? notifyGalleryVisible,
  bool skipPermission = false,
  bool customDirSkipped = false,
}) async {
  // Capability gate: fvp exposes no frame grab — say so instead of failing.
  if (!isMediaKit) return const ScreenshotUnsupported('fvp');

  final Uint8List? rawBytes;
  try {
    rawBytes = await frameSource();
  } catch (e) {
    _log.warning('screenshot frame grab failed: $e');
    return ScreenshotFailure(ScreenshotFailureKind.frameGrab, detail: '$e');
  }
  if (rawBytes == null || rawBytes.isEmpty) {
    return const ScreenshotFailure(ScreenshotFailureKind.emptyFrame);
  }

  // PNG guarantee: the saved `.png` name must match real PNG content.
  // Already-PNG frames pass through untouched (no re-encode cost);
  // anything else is transcoded, and undecodable bytes fail loudly
  // instead of landing as a corrupt file.
  final Uint8List pngBytes;
  if (isPngBytes(rawBytes)) {
    pngBytes = rawBytes;
  } else {
    // Off-isolate by default: a 1080p decode + PNG encode on the UI isolate
    // would jank the player for hundreds of ms. Tests inject their own
    // transcoder, so `compute` is only the production default.
    final transcoded = await (transcodeToPng ??
        (bytes) => compute(transcodeToPngBytes, bytes))(rawBytes);
    if (transcoded == null || transcoded.isEmpty) {
      return const ScreenshotFailure(ScreenshotFailureKind.undecodable);
    }
    pngBytes = transcoded;
  }

  // Carry the session's mirror/rotation into the saved frame. Those transforms
  // are paint-level on the surface, so the raw backend frame does not include
  // them (unlike mpv's own vf filters, which would). A decode/transform/encode
  // failure falls back to the untouched frame rather than losing the shot.
  Uint8List outputBytes = pngBytes;
  if (postProcessPng != null) {
    try {
      final Uint8List? processed = await postProcessPng(pngBytes);
      if (processed != null && processed.isNotEmpty) outputBytes = processed;
    } catch (e) {
      _log.warning('screenshot transform failed: $e');
    }
  }

  // Best-effort permission grant before the public-dir write; denial is
  // not fatal — the fallback chain below still produces a file.
  if (!skipPermission) {
    try {
      await requestStoragePermission();
    } catch (e) {
      _log.warning('screenshot permission probe failed: $e');
    }
  }

  final String? localVideoPath = resolveLocalVideoPath();
  String targetFor(String custom, String def) => resolveScreenshotTargetPath(
        localVideoPath: localVideoPath,
        customDirPath: custom,
        defaultDirPath: def,
        now: now,
      );
  // Ordered write chain: custom → platform default → documents. Each level
  // is tried once; a SAF `content://` custom dir is never passed to `File`
  // (unwritable as a path) — it is skipped straight to the default.
  // Directory creation is async (`Directory.create`) so the first capture
  // never blocks the UI isolate on synchronous filesystem IO.
  final ensure = ensureDir ??
      (String dir) => Directory(dir).create(recursive: true);
  final List<String> chain = {
    if (customDirPath.trim().isNotEmpty && !isSafPath(customDirPath))
      targetFor(customDirPath, defaultDirPath),
    targetFor('', defaultDirPath),
    targetFor('', documentsDirPath),
  }.toList();
  Object? lastError;
  for (final path in chain) {
    try {
      await ensure(p.dirname(path));
      await writeBytes(path, outputBytes);
      try {
        await (notifyGalleryVisible ??
            ScreenshotMediaScan.notifyGalleryVisible)(path);
      } catch (e) {
        _log.warning('screenshot gallery notify failed ($path): $e');
      }
      return ScreenshotSuccess(path, customDirSkipped: customDirSkipped);
    } catch (e) {
      lastError = e;
      _log.warning('screenshot write failed ($path): $e');
    }
  }
  return ScreenshotFailure(ScreenshotFailureKind.write, detail: '$lastError');
}

/// Captures the current video frame as a PNG into the platform default
/// screenshots dir (or the per-platform custom dir when set).
///
/// mediaKit-only capability ([F1] in capability_matrix); other backends
/// answer [ScreenshotUnsupported] so callers can offer the switch.
Future<ScreenshotResult> captureCurrentFrame(MediaPlayer player) async {
  // Capability gate FIRST: an unsupported backend needs no directory probe
  // (and must not hit path_provider just to say "not supported").
  if (player is! MediaKitPlayer) return const ScreenshotUnsupported('fvp');
  // Snapshot the picture transform NOW, before the first await: the frame
  // bytes only arrive later, and a rotation/mirror changed in between must not
  // be baked into a shot of the previous picture.
  final Future<Uint8List?> Function(Uint8List)? screenshotTransform =
      buildScreenshotTransform(useVideoTransformStore().state);
  final String docsPath;
  try {
    final docs = await getApplicationDocumentsDirectory();
    docsPath = docs.path;
  } catch (e) {
    _log.warning('screenshot documents dir failed: $e');
    return ScreenshotFailure(ScreenshotFailureKind.noDir, detail: '$e');
  }
  final String defaultDir;
  try {
    defaultDir = await resolveScreenshotDefaultDir(documentsDirPath: docsPath);
  } catch (e) {
    _log.warning('screenshot default dir failed: $e');
    return ScreenshotFailure(ScreenshotFailureKind.noDir, detail: '$e');
  }
  final String customDirRaw = isMobilePlatform
      ? useAppStore().state.screenshotMobileDir
      : useAppStore().state.screenshotDesktopDir;
  // A picked Android SAF tree URI is mapped to its filesystem path so the
  // plain-File write chain can honor the custom dir. When the mapped path is
  // NOT writable (typically no All-files access) the custom dir is dropped
  // outright: otherwise the chain burns a failed write before falling back,
  // and the user never learns the choice was ignored.
  final ResolvedPick pick = await resolvePickedScreenshotDir(customDirRaw);
  return captureFrameCore(
    isMediaKit: true,
    frameSource: () => player.player.screenshot(format: 'image/png'),
    // Mirror/rotation live in the Flutter paint layer, so bake them into the
    // saved PNG to keep the shot WYSIWYG. Off-isolate: a 1080p
    // decode+transform+encode must not jank the player.
    postProcessPng: screenshotTransform,
    resolveLocalVideoPath: _resolveCurrentPlayingLocalPath,
    customDirPath: pick.path,
    defaultDirPath: defaultDir,
    documentsDirPath: docsPath,
    now: DateTime.now(),
    writeBytes: (path, bytes) => File(path).writeAsBytes(bytes),
    customDirSkipped: pick.skipped,
    // `resolveScreenshotDefaultDir` above already probed storage permission;
    // probing again here only doubles the system-dialog round trip.
    skipPermission: true,
  );
}

/// Resolution of a picked screenshot directory for the capture writer.
///
/// [path] is the directory to feed the write chain (`''` = not usable, fall
/// back to the default); [skipped] is true when a custom choice was DROPPED
/// (mapped but unwritable) so the caller can tell the user, as opposed to a
/// plain "no custom dir set".
typedef ResolvedPick = ({String path, bool skipped});

/// Best-effort resolution of a picked screenshot directory to a storable plain
/// path, plus whether it can actually receive a write.
///
/// - Plain (non-SAF) input is returned verbatim; the write chain itself is the
///   authority on writability there, so `skipped` stays false.
/// - Android SAF tree URIs are mapped through [safTreeUriToPlainPath]; a mapped
///   path is probed for writability. An unwritable or unmappable pick yields
///   `path: ''` + `skipped: true` — the chain then goes straight to the default
///   dir instead of attempting a doomed write.
Future<ResolvedPick> resolvePickedScreenshotDir(String raw) async {
  if (!isSafPath(raw)) return (path: raw, skipped: false);
  final String? root = await androidStorageRoot();
  final String? mapped = safTreeUriToPlainPath(raw, primaryRoot: root);
  if (mapped == null) return (path: '', skipped: true);
  final bool writable = await isDirWritable(mapped);
  return writable ? (path: mapped, skipped: false) : (path: '', skipped: true);
}

/// Probes whether [dir] can receive a file write.
///
/// Creates the directory, writes and immediately deletes a probe file. This is
/// the only reliable signal for the Android case: the mapped path LOOKS valid
/// but a plain `File` write is rejected without All-files access. Best-effort —
/// any error means "not writable".
Future<bool> isDirWritable(String dir) async {
  final Directory target = Directory(dir);
  try {
    await target.create(recursive: true);
    final File probe =
        File(p.join(dir, '.iris_write_probe_${DateTime.now().microsecondsSinceEpoch}'));
    await probe.writeAsString('');
    await probe.delete();
    return true;
  } catch (_) {
    return false;
  }
}

/// Best-effort Android shared-storage root (`/storage/emulated/0`).
///
/// Derived from `getExternalStorageDirectory()`
/// (`<root>/Android/data/<pkg>/files`) by walking up to the storage root.
/// Null when external storage is unavailable.
Future<String?> androidStorageRoot() async {
  try {
    final ext = await getExternalStorageDirectory();
    if (ext == null) return null;
    String root = ext.path;
    final marker = '${p.separator}Android${p.separator}';
    final idx = root.indexOf(marker);
    if (idx > 0) root = root.substring(0, idx);
    return root;
  } catch (_) {
    return null;
  }
}

/// Resolves the platform default screenshots directory, creating it.
///
/// - Android: public `Pictures/IRIS Screenshots` derived from the external
///   storage dir; falls back to the documents dir when the shared storage
///   root is unreachable.
/// - Portable desktop: `<portableRoot>/screenshots` (moves with the pack).
/// - Installed desktop: OS pictures dir (`%USERPROFILE%/Pictures`,
///   `$XDG_PICTURES_DIR`/`~/Pictures`, `~/Pictures`).
/// - Any other failure (unwritable root, missing env): the documents dir.
///
/// Throws only when even the documents fallback cannot be ensured — the
/// caller then reports "cannot locate the save directory".
Future<String> resolveScreenshotDefaultDir({
  String? documentsDirPath,
  String? portableRootOverride,
  String? picturesDirOverride,
  bool skipPermissionProbe = false,
}) async {
  final String docs = documentsDirPath ??
      (await getApplicationDocumentsDirectory()).path;
  // Async directory creation: the first-ever capture used `createSync` on
  // the UI isolate, which froze the app behind the permission dialog and
  // the public-Pictures mkdir. Awaited async IO keeps the shutter alive.
  Future<String> ensure(String dir) async {
    await Directory(dir).create(recursive: true);
    return dir;
  }

  if (isAndroid) {
    if (!skipScreenshotPermissionProbe && !skipPermissionProbe) {
      try {
        await requestStoragePermission();
      } catch (e) {
        _log.warning('screenshot permission probe failed: $e');
      }
    }
    final String? pictures =
        picturesDirOverride ?? await _androidPicturesDir();
    if (pictures != null && pictures.isNotEmpty) {
      try {
        return await ensure(defaultScreenshotSubdir(
          isAndroid: true,
          isPortable: false,
          portableRoot: null,
          picturesDir: pictures,
        ));
      } catch (e) {
        _log.warning('screenshot public dir unusable, degrade: $e');
      }
    }
    return await ensure(docs);
  }

  final bool portable = portableRootOverride != null
      ? portableRootOverride.isNotEmpty
      : AppPaths.isPortable;
  final String? root = portableRootOverride ??
      (portable ? AppPaths.layout?.rootPath : null);
  String pictures = picturesDirOverride ?? _desktopPicturesDir(docs);
  if (portable && root != null && root.isNotEmpty) {
    try {
      return await ensure(defaultScreenshotSubdir(
        isAndroid: false,
        isPortable: true,
        portableRoot: root,
        picturesDir: pictures,
      ));
    } catch (e) {
      _log.warning('screenshot portable dir unusable, degrade: $e');
    }
  }
  try {
    return await ensure(defaultScreenshotSubdir(
      isAndroid: false,
      isPortable: false,
      portableRoot: null,
      picturesDir: pictures,
    ));
  } catch (_) {
    return await ensure(p.join(docs, kDesktopScreenshotFolder));
  }
}

/// Test seam: widget/unit tests skip the permission-channel probe (no
/// platform-channel host under `flutter test`).
bool skipScreenshotPermissionProbe = false;

/// Best-effort Android public Pictures dir (`/storage/emulated/0/Pictures`).
/// Null when the external storage root cannot be determined.
Future<String?> _androidPicturesDir() async {
  final String? root = await androidStorageRoot();
  return root == null ? null : p.join(root, 'Pictures');
}

/// Installed-desktop pictures dir with per-OS fallbacks.
String _desktopPicturesDir(String docs) {
  if (isWindows) {
    final String? profile = Platform.environment['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) {
      return p.join(profile, 'Pictures');
    }
    return docs;
  }
  if (isLinux) {
    final String? xdg = Platform.environment['XDG_PICTURES_DIR'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    final String? home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) return p.join(home, 'Pictures');
    return docs;
  }
  if (isMacOS) {
    final String? home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) return p.join(home, 'Pictures');
    return docs;
  }
  return docs;
}

/// Best-effort warmup of the platform default screenshots directory.
///
/// Called once from startup (`completeStartupInitialization`, unawaited) so
/// the first shutter tap skips the public-dir mkdir that used to freeze the
/// UI. It deliberately does NOT request storage permission: a prewarm must
/// never pop the All-files-access prompt before the user asks for a
/// screenshot. Never throws; failures surface on the real capture attempt.
Future<void> prewarmScreenshotDir() async {
  try {
    await resolveScreenshotDefaultDir(skipPermissionProbe: true);
  } catch (e) {
    _log.warning('screenshot dir prewarm failed: $e');
  }
}

/// Resolves the currently playing LOCAL file path from the unified play
/// queue; null for remote sources or when nothing plays.
String? _resolveCurrentPlayingLocalPath() {
  final state = usePlayQueueStore().state;
  for (final item in state.playQueue) {
    if (item.index != state.currentIndex) continue;
    final uri = item.file.uri;
    if (uri.isEmpty || uri.startsWith('http')) return null;
    try {
      final path = uri.startsWith('file:')
          ? Uri.parse(uri)
              .toFilePath()
              .replaceFirst(RegExp(r'^/([A-Za-z]:)'), r'$1')
          : uri;
      return File(path).existsSync() ? path : null;
    } catch (_) {
      return null;
    }
  }
  return null;
}
