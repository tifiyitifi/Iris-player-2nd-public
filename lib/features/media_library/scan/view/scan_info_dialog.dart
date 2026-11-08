import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/media_library/scan/model/scan_cost_model.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/format_duration_hms.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';

/// What a pre-scan prompt covers.
///
/// Derived from `rootPath` by default (null/empty → the whole storage); the
/// scenario actions override it, because they scan a batch of source folders
/// rather than one storage or one folder.
enum ScanInfoScope { storage, folder, sources }

/// Pre-scan explainer: what will be read, how long it takes, what to watch
/// out for, and whether the completion countdown should be skipped.
///
/// Replaces the old "read media info?" checkbox, which asked about an
/// implementation detail while hiding the costs that actually matter. The
/// probe is now always on (see `kShowScanProbeOption` in
/// scan_options_dialog.dart), so this dialog returns `true` on confirm and
/// `null` on cancel — the same contract as before.
class ScanInfoDialog extends HookWidget {
  const ScanInfoDialog({
    super.key,
    required this.storage,
    this.rootPath,
    this.scope,
  });

  final Storage storage;

  /// Canonical path of the folder to scan; null/empty means the whole storage.
  final String? rootPath;

  /// Overrides the scope derived from [rootPath] (scenario batch scans).
  final ScanInfoScope? scope;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = getLocalizations(context);
    final theme = Theme.of(context);
    final scanStore = useRecursiveScanStore();

    final folderPath = rootPath ?? '';
    final scopeKind = scope ??
        (folderPath.isEmpty ? ScanInfoScope.storage : ScanInfoScope.folder);

    // The checkbox is the inverse of the persisted preference: it starts
    // checked when the countdown is currently enabled.
    final silent = useState(!scanStore.state.autoClosePrompt);
    final known = useState<_KnownCounts?>(null);

    useEffect(() {
      if (scopeKind == ScanInfoScope.sources) return null;
      var cancelled = false;
      // Whole-storage estimates must name the storage base itself: SAF
      // scopes never create the `''` container row (their root row carries
      // the full `content://...` URI), so `['']` would always read 0.
      final roots = scopeKind == ScanInfoScope.folder
          ? <String>[folderPath]
          : <String>[
              storage.basePath.isEmpty ? '' : storage.basePath.join('/'),
            ];
      final prefix = scopeKind == ScanInfoScope.folder ? folderPath : null;
      () async {
        try {
          final dao = DbModule.mediaNodesDao;
          // countDirsUnder returns 0 unless the stored snapshot is COMPLETE,
          // which doubles as the "do we know anything at all?" gate — no
          // estimate is better than a fabricated one.
          final dirs = await dao.countDirsUnder(storage.id, roots);
          if (cancelled || dirs <= 0) return;
          final files = await dao.countFilesForMetadata(
            storage.id,
            pathPrefix: prefix,
            includeExisting: true,
          );
          if (!cancelled) known.value = _KnownCounts(dirs: dirs, files: files);
        } catch (_) {
          // Best-effort readout; a failed count simply hides the line.
        }
      }();
      return () => cancelled = true;
    }, [storage.id, scopeKind, folderPath]);

    final knownCounts = known.value;
    String? knownText;
    if (knownCounts != null) {
      final eta = estimatedScanDuration(
        dirs: knownCounts.dirs,
        files: knownCounts.files,
        isWindows: Platform.isWindows,
      );
      if (eta != null) {
        final files = MaterialLocalizations.of(context)
            .formatDecimal(knownCounts.files);
        final time = formatDurationHms(eta);
        knownText = scopeKind == ScanInfoScope.folder
            ? t.scan_info_known_folder(files, time)
            : t.scan_info_known(files, time);
      }
    }

    final bool isRemote = storage.type == StorageType.webdav ||
        storage.type == StorageType.ftp ||
        storage.type == StorageType.network;
    final bool showWholeDiskWarning = Platform.isWindows &&
        !isRemote &&
        scopeKind == ScanInfoScope.storage;

    final scopeText = switch (scopeKind) {
      ScanInfoScope.storage => t.scan_info_scope_storage(storage.name),
      ScanInfoScope.folder => t.scan_info_scope_folder(_folderName(folderPath)),
      ScanInfoScope.sources => t.scan_info_scope_sources,
    };

    final bodySmall = theme.textTheme.bodySmall;
    final delay = scanStore.state.autoCloseDelay;

    return AlertDialog(
      title: Text(t.scan_info_title),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(scopeText, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 10),
            ScanInfoBody(
              storageType: storage.type,
              knownText: knownText,
              showWholeDiskWarning: showWholeDiskWarning,
              showDirEstimate: true,
            ),
            const Divider(height: 24),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: silent.value,
              onChanged: (v) => silent.value = v == true,
              title: Text(t.scan_info_silent_label),
            ),
            Text(t.scan_info_silent_hint, style: bodySmall),
            if (!silent.value && delay > 0) ...[
              const SizedBox(height: 6),
              Text(
                t.scan_info_silent_current(delay.toStringAsFixed(1)),
                style: bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(t.scan_cancel),
        ),
        ElevatedButton(
          onPressed: () async {
            final prompt = !silent.value;
            if (prompt != scanStore.state.autoClosePrompt) {
              await scanStore.updateAutoClosePrompt(prompt);
            }
            if (context.mounted) Navigator.of(context).pop(true);
          },
          child: Text(t.scan_start),
        ),
      ],
    );
  }

  /// Last segment of a storage-relative folder path, for the scope sentence.
  /// SAF document/tree URIs are unreadable raw, so display-decode first.
  static String _folderName(String path) {
    final display = isSafPath(path) ? safDisplayPath(path) : path;
    final parts = display.split(RegExp(r'[\\/]'))
      ..removeWhere((p) => p.isEmpty);
    return parts.isEmpty ? display : parts.last;
  }
}

/// The informational half of the pre-scan prompt, shared with the folder-rescan
/// dialog (which keeps its own policy radios and scope sentence).
class ScanInfoBody extends StatelessWidget {
  const ScanInfoBody({
    super.key,
    required this.storageType,
    this.knownText,
    this.showWholeDiskWarning = false,
    this.showDirEstimate = false,
  });

  final StorageType storageType;

  /// Localized "records N media files — estimated about X" line; null hides it.
  final String? knownText;

  final bool showWholeDiskWarning;

  /// Shows the per-folder cost reference (profile-measured, all platforms).
  /// Only the pre-scan explainer sets it; the folder-rescan dialog keeps its
  /// own copy unchanged.
  final bool showDirEstimate;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = getLocalizations(context);
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    final bool isRemote = storageType == StorageType.webdav ||
        storageType == StorageType.ftp ||
        storageType == StorageType.network;

    // Remote storages have their own cost sentence (the local-disk numbers do
    // not apply to a link). Local scans show one reference line on every
    // platform: the quantity is the point, not which device is running the
    // scan, so the phone and desktop figures are quoted together.
    final String cost = isRemote ? t.scan_info_remote : t.scan_info_cost_local;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(t.scan_info_reads, style: style),
        const SizedBox(height: 8),
        Text(cost, style: style),
        if (showDirEstimate) ...[
          const SizedBox(height: 8),
          Text(t.scan_info_cost_dirs, style: style),
        ],
        const SizedBox(height: 8),
        Text(t.scan_info_estimate_caveat, style: style),
        if (showWholeDiskWarning) ...[
          const SizedBox(height: 8),
          Text(
            t.scan_info_win_whole_disk,
            style: style?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        if (knownText != null) ...[
          const SizedBox(height: 8),
          Text(knownText!, style: style),
        ],
        const SizedBox(height: 8),
        Text(t.scan_info_advice, style: style),
        const SizedBox(height: 8),
        Text(t.scan_info_note_pause, style: style),
        const SizedBox(height: 4),
        Text(t.scan_info_note_resume, style: style),
        const SizedBox(height: 4),
        Text(t.scan_info_note_unreadable, style: style),
      ],
    );
  }
}

class _KnownCounts {
  const _KnownCounts({required this.dirs, required this.files});

  final int dirs;
  final int files;
}
