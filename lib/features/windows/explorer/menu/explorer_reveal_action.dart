import 'package:flutter/material.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/windows/explorer/services/explorer_reveal_service.dart';
import 'package:iris/models/file.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/platform.dart';

/// Shared "Open in Explorer" menu entry for a paged-browser row.
///
/// Returns an empty list when the entry does not apply — not Windows, remote
/// storage, or no on-disk identity — so call sites spread it unconditionally
/// (`...buildExplorerRevealActions(...)`). Because every surface shares this
/// builder, the trailing "more" button and the desktop right-click menu can
/// never drift.
List<GenericItemAction<T>> buildExplorerRevealActions<T>({
  required BuildContext context,
  required T item,
  required FileItem? Function(T item) fileOf,
  bool? onWindows,
  ExplorerLauncher? launcher,
}) {
  final windows = onWindows ?? isWindows;
  if (!windows) return const [];
  final file = fileOf(item);
  if (file == null) return const [];
  // Re-checked through the shared gate with the same override, so an explicit
  // `onWindows: false` can never be overridden by the test host.
  if (!canRevealFileInExplorer(file, onWindows: windows)) return const [];
  final t = getLocalizations(context);
  return [
    GenericItemAction<T>(
      label: t.open_in_explorer,
      icon: const Icon(Icons.desktop_windows_rounded, size: 16),
      onPressed: (ctx, _) => _revealRow(ctx, file, launcher, windows),
    ),
  ];
}

/// Whether [file] can be revealed on this host — for menu-entry gating in
/// surfaces that are not a [GenericItemAction] list (the legacy popups).
bool canRevealFileInExplorer(FileItem file, {bool? onWindows}) {
  if (!(onWindows ?? isWindows)) return false;
  return isExplorerRevealVisible(
    onWindows: true,
    storageType: file.storageType,
    segments: file.path,
    persistedUri: file.uri,
  );
}

/// Direct entry point for surfaces that are not a [GenericItemAction] list:
/// reveals [file] and explains a hard failure. Rows without an on-disk identity
/// are a silent no-op.
Future<void> revealFileInExplorer(BuildContext context, FileItem file) =>
    _revealRow(context, file, null, isWindows);

/// Runs the reveal and explains a hard failure. A downgraded reveal (missing
/// file → its folder) is not a failure and stays silent.
Future<void> _revealRow(
  BuildContext context,
  FileItem file,
  ExplorerLauncher? launcher,
  bool onWindows,
) async {
  final outcome = await revealInExplorer(
    storageType: file.storageType,
    segments: file.path,
    persistedUri: file.uri,
    isDir: file.isDir,
    onWindows: onWindows,
    launcher: launcher ?? defaultExplorerLauncher,
  );
  if (outcome != ExplorerRevealOutcome.folderMissing &&
      outcome != ExplorerRevealOutcome.launchFailed) {
    return;
  }
  if (!context.mounted) return;
  final t = getLocalizations(context);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(t.reveal_in_explorer_failed_title),
      content: Text(
        outcome == ExplorerRevealOutcome.folderMissing
            ? t.reveal_in_explorer_missing_body
            : t.reveal_in_explorer_failed_body,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(t.ok),
        ),
      ],
    ),
  );
}
