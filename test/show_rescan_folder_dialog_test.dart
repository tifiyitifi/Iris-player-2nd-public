import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/view/dialogs/show_rescan_folder_dialog.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/get_localizations.dart';

// The merged rescan dialog: one prompt that decides the folder's source policy
// AND the deep-probe flag. Defaults to "add recursively".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<
      ({
        RescanFolderChoice? Function() result,
        String startLabel,
        String cancelLabel,
        String scanOnlyLabel,
      })> openDialog(WidgetTester tester) async {
    RescanFolderChoice? captured;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(builder: (context) {
          return ElevatedButton(
            onPressed: () async {
              captured = await showRescanFolderDialog(
                context,
                storageType: StorageType.internal,
                folderName: 'a/b',
              );
            },
            child: const Text('open'),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Read the localized labels from the dialog's own (now-mounted) context —
    // deferred l10n is only guaranteed loaded after the settle above.
    final t = getLocalizations(tester.element(find.byType(RescanFolderDialog)));
    return (
      result: () => captured,
      startLabel: t.scan_start,
      cancelLabel: t.scan_cancel,
      scanOnlyLabel: t.scn_rescan_folder_scan_only,
    );
  }

  testWidgets('shows three policies and defaults to add-recursive',
      (tester) async {
    final handle = await openDialog(tester);
    expect(find.byType(RadioListTile<RescanFolderPolicy>), findsNWidgets(3));

    await tester.tap(find.text(handle.startLabel));
    await tester.pumpAndSettle();

    final choice = handle.result();
    expect(choice, isNotNull);
    expect(choice!.policy, RescanFolderPolicy.addRecursive);
    expect(choice.probe, isTrue);
  });

  testWidgets('returns the scan-only policy when chosen', (tester) async {
    final handle = await openDialog(tester);
    await tester.tap(find.text(handle.scanOnlyLabel));
    await tester.pumpAndSettle();

    await tester.tap(find.text(handle.startLabel));
    await tester.pumpAndSettle();

    expect(handle.result()!.policy, RescanFolderPolicy.scanOnly);
  });

  testWidgets('cancel returns null', (tester) async {
    final handle = await openDialog(tester);
    await tester.tap(find.text(handle.cancelLabel));
    await tester.pumpAndSettle();
    expect(handle.result(), isNull);
  });
}
