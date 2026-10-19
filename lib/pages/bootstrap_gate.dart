import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/app_startup.dart';
import 'package:iris/features/app_update/view/report_previous_update.dart';
import 'package:iris/store/kv/secure_kv.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/app_paths.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/portable_import.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';
import 'package:iris/widgets/dialogs/show_portable_import_dialog.dart';

final areaKeyLog = AreaKeyLog(LogKeys.legacyMain);

/// Startup gate rendered as [MyApp]'s home.
///
/// Blocks [child] behind a splash until the deferred startup sequence
/// (`completeStartupInitialization`) has run. On a portable first launch it
/// first offers the one-time import of installed-mode data — BEFORE any
/// database or store initialization, so migrated state is what everything
/// loads.
///
/// Any failure in the startup sequence surfaces a recoverable error screen
/// (Retry / Quit) instead of an endless spinner: without it a corrupt database
/// or a failed migration left the user staring at a splash with no way out.
class BootstrapGate extends HookWidget {
  const BootstrapGate({super.key, required this.child, this.initialize});

  final Widget child;

  /// Startup sequence runner. Defaults to [completeStartupInitialization];
  /// injectable so tests can exercise the failure/retry paths without booting
  /// the whole app (DB, plugins, network).
  final Future<void> Function()? initialize;

  @override
  Widget build(BuildContext context) {
    final ready = useState(false);
    final errorText = useState<String?>(null);
    final attempt = useState(0);

    useEffect(() {
      () async {
        final navigator = Navigator.of(context, rootNavigator: true);
        errorText.value = null;

        try {
          await runPortableFirstRunFlow(context);
        } catch (e, s) {
          areaKeyLog.e('Portable first-run flow failed: $e', e, s);
        }

        if (AppPaths.fallbackReason != null && navigator.mounted) {
          final t = getLocalizations(context);
          await showMessageDialog(
            navigator,
            type: MessageDialogType.error,
            title: t.portable_fallback_title,
            message: t.portable_fallback_body,
          );
        }

        // What became of the last in-app portable update, if one was handed
        // over before this launch. After the fallback notice so the two never
        // race for the same frame, and before the app is shown so the answer
        // arrives with it.
        try {
          await reportPreviousPortableUpdate(navigator);
        } catch (e, s) {
          areaKeyLog.e('Update report failed: $e', e, s);
        }

        try {
          await (initialize ?? completeStartupInitialization)();
          ready.value = true;
        } catch (e, s) {
          // Keep the user out of the dead-spinner state and out of the app:
          // continuing with an uninitialized DB would corrupt data.
          areaKeyLog.e('Startup initialization failed: $e', e, s);
          errorText.value = e.toString();
        }
      }();
      return null;
    }, [attempt.value]);

    if (ready.value) return child;
    if (errorText.value != null) {
      return _StartupFailureScreen(
        error: errorText.value!,
        onRetry: () => attempt.value++,
      );
    }
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

/// Recoverable startup failure: explains what happened and lets the user retry
/// or exit, instead of leaving an unresolvable splash.
class _StartupFailureScreen extends StatelessWidget {
  const _StartupFailureScreen({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.error_outline,
                    size: 48, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 16),
                Text(
                  t.startup_failed_title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                SelectableText(
                  t.startup_failed_body(error),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () => exit(0),
                      child: Text(t.startup_failed_quit),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: onRetry,
                      child: Text(t.startup_failed_retry),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One-time legacy-data import flow for portable mode. No-op outside
/// portable mode or when the question was already settled.
Future<void> runPortableFirstRunFlow(BuildContext context) async {
  if (!AppPaths.isPortable) return;
  final layout = AppPaths.layout!;
  final fileKv = portableFileKv;
  if (fileKv == null) return;

  if (await isPortableImportAlreadyDecided(fileKv)) return;

  final dbPaths = await resolvePortableMigrationDbPaths(layout);
  final legacyKv = SecureStorageKv();
  final scan = await scanPortableImportSources(
    legacyDbFilePath: dbPaths.legacyPath,
    legacyKv: legacyKv,
  );

  if (!scan.anything) {
    // Nothing to import now or ever: settle the decision permanently.
    await markPortableImportSkipped(fileKv);
    return;
  }

  if (!context.mounted) return;
  final confirmed = await showPortableImportDialog(context, scan: scan);
  if (!confirmed) {
    await markPortableImportSkipped(fileKv);
    areaKeyLog.i('Portable import declined by user');
    return;
  }

  final outcome = await performPortableImport(
    legacyDbFilePath: dbPaths.legacyPath,
    targetDbFilePath: dbPaths.portablePath,
    legacyKv: legacyKv,
    targetKv: fileKv,
  );

  // AppStore initializes during MyApp's very first build — above this gate —
  // so it saw empty portable storage. Refresh it from the imported blob.
  // All other stores initialize later (inside the startup sequence below)
  // and read the imported values naturally.
  await useAppStore().reload();

  areaKeyLog.i('Portable import finished: $outcome');
}
