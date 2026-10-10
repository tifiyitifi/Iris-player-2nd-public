import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/windows/explorer/menu/explorer_reveal_action.dart';
import 'package:iris/features/windows/explorer/services/explorer_reveal_service.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/get_localizations.dart';

// The row action is built once and shared by the trailing "more" button and the
// desktop right-click menu; this pins that it appears exactly for Windows-local
// rows and that its handler drives the (injected) shell launcher.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<
      ({
        List<GenericItemAction<FileItem>> actions,
        String label,
        BuildContext context,
      })> buildFor(
    WidgetTester tester,
    FileItem item, {
    bool onWindows = true,
    ExplorerLauncher? launcher,
  }) async {
    late List<GenericItemAction<FileItem>> actions;
    late String label;
    late BuildContext captured;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(builder: (context) {
          captured = context;
          label = getLocalizations(context).open_in_explorer;
          actions = buildExplorerRevealActions<FileItem>(
            context: context,
            item: item,
            fileOf: (f) => f,
            onWindows: onWindows,
            launcher: launcher,
          );
          return const SizedBox();
        }),
      ),
    ));
    await tester.pumpAndSettle();
    return (actions: actions, label: label, context: captured);
  }

  testWidgets('local file row on Windows gets the entry', (tester) async {
    final result = await buildFor(
      tester,
      const FileItem(
        storageId: 's',
        storageType: StorageType.internal,
        name: 'a.mp4',
        uri: 'E:\\yb\\a.mp4',
        path: ['E:', 'yb', 'a.mp4'],
        type: ContentType.video,
      ),
    );
    expect(result.actions, hasLength(1));
    expect(result.actions.single.label, result.label);
    expect(result.actions.single.label, isNotEmpty);
  });

  testWidgets('remote (WebDAV) row gets no entry', (tester) async {
    final result = await buildFor(
      tester,
      const FileItem(
        storageId: 's',
        storageType: StorageType.webdav,
        name: 'a.mp4',
        uri: 'http://host/Movies/a.mp4',
        path: ['Movies', 'a.mp4'],
        type: ContentType.video,
      ),
    );
    expect(result.actions, isEmpty);
  });

  testWidgets('non-Windows host gets no entry', (tester) async {
    final result = await buildFor(
      tester,
      const FileItem(
        storageId: 's',
        storageType: StorageType.internal,
        name: 'a.mp4',
        uri: 'E:\\yb\\a.mp4',
        path: ['E:', 'yb', 'a.mp4'],
        type: ContentType.video,
      ),
      onWindows: false,
    );
    expect(result.actions, isEmpty);
  });

  testWidgets('pressing the entry reveals the row through the launcher',
      (tester) async {
    // An existing directory keeps the probe deterministic without creating a
    // file; the /select request shape is pinned in the service test.
    final dir = Directory.systemTemp.path;
    final requests = <ExplorerRevealRequest>[];
    final result = await buildFor(
      tester,
      FileItem(
        storageId: 's',
        storageType: StorageType.internal,
        name: 'Temp',
        uri: dir,
        path: [dir],
        isDir: true,
        type: ContentType.other,
      ),
      launcher: (request) async => requests.add(request),
    );
    expect(result.actions, hasLength(1));

    result.actions.single.onPressed(result.context, null);
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    expect(requests.single.selectsFile, isFalse);
    expect(requests.single.folderPath, dir);
  });
}
