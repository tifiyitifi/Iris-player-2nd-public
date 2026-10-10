import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/utils/platform.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart' show SW_SHOWNORMAL, ShellExecute;

final _log = AreaKeyLog(LogKeys.legacyUi);

/// Storage kinds whose entries live on a real filesystem Explorer can show.
///
/// `network` is included — a Windows network shortcut resolves to a UNC path —
/// unlike `open_with_service`'s device-local-only set. `webdav`/`ftp` exist
/// only as remote URLs, and `none` is the placeholder for unknown rows.
const Set<StorageType> revealableStorageTypes = {
  StorageType.internal,
  StorageType.network,
  StorageType.usb,
  StorageType.sdcard,
};

/// Drive-letter (`E:/…`) or UNC (`//server/share/…`): the only Windows forms
/// Explorer accepts. A URL or a storage-relative segment list is refused, so
/// Explorer is never handed something it cannot locate.
final RegExp _kWindowsAbsolutePath = RegExp(r'^([A-Za-z]:/|//)');

/// What a reveal attempt did, so the caller can decide whether to explain it.
enum ExplorerRevealOutcome {
  /// Explorer was handed the request.
  launched,

  /// The row has no on-disk identity (remote storage, SAF document) — nothing
  /// was opened.
  notApplicable,

  /// Neither the file nor its folder exists any more.
  folderMissing,

  /// Explorer could not be started.
  launchFailed,
}

/// A ready-to-run Explorer reveal.
///
/// [parameters] is the RAW `explorer.exe` command string (`/select,"<path>"`)
/// when a file must be highlighted; null means "open [folderPath] directly"
/// (a directory row, or a file whose own path is gone).
class ExplorerRevealRequest {
  const ExplorerRevealRequest({
    required this.folderPath,
    required this.parameters,
  });

  /// Native (backslash) absolute path of the folder to open.
  final String folderPath;

  /// Raw `lpParameters` for `explorer.exe`, or null to open [folderPath] as a
  /// shell folder.
  final String? parameters;

  /// True when the request selects a file rather than opening a folder.
  bool get selectsFile => parameters != null;

  @override
  String toString() =>
      'ExplorerRevealRequest(folder=$folderPath, params=$parameters)';
}

/// Test seam for the shell hand-off: injected so tests can record the request
/// without opening a real window.
typedef ExplorerLauncher = Future<void> Function(ExplorerRevealRequest request);

/// Whether a path currently exists (test seam for the filesystem probe).
typedef ExistsProbe = bool Function(String path);

/// Opens the request through `ShellExecuteW`.
///
/// `ShellExecute` takes `lpParameters` as a RAW command line, which is exactly
/// what `explorer.exe`'s own parser expects. `Process.start` cannot be used
/// here: it re-quotes and escapes the embedded quotes per `CreateProcess`
/// rules, and Explorer then reads `/select,` plus a literal quote as a
/// malformed object and falls back to its default folder (Documents).
Future<void> defaultExplorerLauncher(ExplorerRevealRequest request) async {
  final operation = 'open'.toNativeUtf16();
  final file =
      (request.parameters == null ? request.folderPath : 'explorer.exe')
          .toNativeUtf16();
  final parameters = request.parameters?.toNativeUtf16() ?? nullptr;
  try {
    final result = ShellExecute(
      0,
      operation,
      file,
      parameters,
      nullptr,
      SW_SHOWNORMAL,
    );
    if (result <= 32) {
      // ShellExecute returns a value > 32 on success; anything else is an
      // error code (or a legacy HINSTANCE-shaped failure).
      throw ProcessException(
        'ShellExecute',
        [request.folderPath],
        'Explorer hand-off refused (code $result)',
      );
    }
  } finally {
    calloc.free(operation);
    calloc.free(file);
    if (parameters != nullptr) calloc.free(parameters);
  }
}

bool defaultExistsProbe(String path) =>
    FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

/// Visibility gate for the "Open in Explorer" row entry.
///
/// Mirrors `isOpenWithActionVisible`: a pure function of the platform, the
/// storage kind and the row's on-disk identity, so the policy is pinned in a
/// unit test instead of in a comment.
bool isExplorerRevealVisible({
  required bool onWindows,
  required StorageType storageType,
  required List<String> segments,
  String? persistedUri,
}) {
  if (!onWindows) return false;
  if (!revealableStorageTypes.contains(storageType)) return false;
  if (isSafMediaUri(persistedUri ?? '')) return false;
  return explorerRevealPath(
        segments: segments,
        persistedUri: persistedUri,
        storageType: storageType,
      ) !=
      null;
}

/// Absolute Windows path for a device-local row, or null when the row has no
/// on-disk identity.
///
/// The segment list is authoritative (that is what listings and the DB build),
/// with the persisted uri as the fallback for rows whose segments cannot be
/// joined into a path. Only the drive-letter / UNC shape is accepted, so a
/// remote URL, a SAF document or a storage-relative list all resolve to null.
///
/// [storageType] disambiguates a network row: the path codec stores a UNC
/// shortcut's `\\server\share` base SPLIT into `server`,`share` (its
/// `canonicalDbPath` drops the leading `\\`), so [playableUri] cannot rebuild
/// the `//` marker and an otherwise-correct SMB row would look like a
/// storage-relative list. A network row's leading two segments ARE host+share,
/// so the UNC form is rebuilt from them.
String? explorerRevealPath({
  required List<String> segments,
  String? persistedUri,
  StorageType storageType = StorageType.none,
}) {
  final cleaned = segments.where((s) => s.isNotEmpty).toList();
  final candidates = <String>[
    if (cleaned.isNotEmpty) playableUri(cleaned),
    if (storageType == StorageType.network && cleaned.isNotEmpty)
      '//${cleaned.join('/')}',
    if (persistedUri != null && persistedUri.isNotEmpty)
      _persistedUriToPath(persistedUri) ?? '',
  ];
  for (final candidate in candidates) {
    if (candidate.isEmpty) continue;
    // `sanitizePlayableUri` repairs the legacy pre-fix '/E:/…' shape.
    final normalized =
        sanitizePlayableUri(candidate).replaceAll('\\', '/');
    if (_kWindowsAbsolutePath.hasMatch(normalized)) return normalized;
  }
  return null;
}

/// Converts a persisted row uri into a Windows path candidate.
///
/// `file:` URIs are decoded; `http(s)`/`ftp`/`content:` are rejected — they are
/// addresses, not paths. A plain path passes through for the shape check to
/// accept or reject.
String? _persistedUriToPath(String raw) {
  if (raw.startsWith('file:')) {
    try {
      return Uri.parse(raw).toFilePath();
    } catch (_) {
      return null;
    }
  }
  if (raw.startsWith('content:') ||
      raw.startsWith('http://') ||
      raw.startsWith('https://') ||
      raw.startsWith('ftp')) {
    return null;
  }
  return raw;
}

/// Pure request builder for [absolutePath] (forward-slash normalized form).
///
/// - an existing file selects via `/select,"<native>"`;
/// - an existing directory opens itself;
/// - a missing file degrades to its parent folder;
/// - a directory that is missing degrades to its parent too.
ExplorerRevealRequest explorerRevealRequest(
  String absolutePath, {
  required bool targetExists,
  required bool isDir,
}) {
  final native = absolutePath.replaceAll('/', r'\');
  if (targetExists && !isDir) {
    return ExplorerRevealRequest(
      folderPath: p.windows.dirname(native),
      parameters: '/select,"$native"',
    );
  }
  if (targetExists) {
    return ExplorerRevealRequest(folderPath: native, parameters: null);
  }
  return ExplorerRevealRequest(
    folderPath: p.windows.dirname(native),
    parameters: null,
  );
}

/// Opens Windows Explorer at the row's location, selecting the file when it
/// still exists and degrading to its folder when it does not.
Future<ExplorerRevealOutcome> revealInExplorer({
  required StorageType storageType,
  required List<String> segments,
  String? persistedUri,
  bool isDir = false,
  bool? onWindows,
  ExplorerLauncher launcher = defaultExplorerLauncher,
  ExistsProbe exists = defaultExistsProbe,
}) async {
  if (!isExplorerRevealVisible(
    onWindows: onWindows ?? isWindows,
    storageType: storageType,
    segments: segments,
    persistedUri: persistedUri,
  )) {
    return ExplorerRevealOutcome.notApplicable;
  }

  final target = explorerRevealPath(
    segments: segments,
    persistedUri: persistedUri,
    storageType: storageType,
  )!;
  final targetExists = exists(target);
  // A degraded reveal (missing file → parent) still needs the parent to exist,
  // otherwise Explorer would raise its own modal error. Probed through the same
  // normalized form as [target]; only the request uses native separators.
  if (!targetExists && !exists(p.windows.dirname(target))) {
    return ExplorerRevealOutcome.folderMissing;
  }

  final request = explorerRevealRequest(
    target,
    targetExists: targetExists,
    isDir: isDir,
  );
  try {
    await launcher(request);
    // DEV diagnostics: the reveal has no other observability, and the exact
    // target/parameters are what a wrong-folder report needs.
    _log.w('explorer_reveal launched $request');
    return ExplorerRevealOutcome.launched;
  } catch (error) {
    _log.w('explorer_reveal failed for $target: $error');
    return ExplorerRevealOutcome.launchFailed;
  }
}
