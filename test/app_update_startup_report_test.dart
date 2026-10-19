import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/services/update_handoff.dart';
import 'package:iris/features/app_update/view/report_previous_update.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/app_paths.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

/// Portable mode is resolved from the executable directory, so this whole
/// scenario only exists on Windows.
final bool _skipOffWindows = !Platform.isWindows;

void main() {
  late AppLocalizations t;
  late Directory root;
  late Directory updates;

  setUpAll(() async {
    t = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('iris-update-report-test');
    File(p.join(root.path, 'portable.flag')).createSync();
  });

  tearDown(() {
    AppPaths.resetForTest();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Resolves portable mode against the temporary directory and seeds a
  /// hand-off record, exactly as a launch that closed for an update would
  /// leave behind.
  Future<File> seedHandoff(WidgetTester tester, {required String toVersion}) async {
    late File package;
    await tester.runAsync(() async {
      await AppPaths.init(exeDirOverride: root);
      updates = Directory(p.join(root.path, AppPaths.userDataDirName, 'updates'))
        ..createSync(recursive: true);
      package = File(p.join(updates.path, 'IRIS-windows-v$toVersion.zip'))
        ..writeAsBytesSync(const <int>[0x50, 0x4B, 0x03, 0x04]);
      await recordPendingUpdate(
        workDir: updates.path,
        fromVersion: '2.0.7',
        toVersion: toVersion,
        packagePath: package.path,
      );
    });
    return package;
  }

  Future<void> report(WidgetTester tester) async {
    late NavigatorState navigator;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            navigator = Navigator.of(context, rootNavigator: true);
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Started inside runAsync: the report reads and deletes real files, and
    // those futures never settle on the test's fake event loop. Not awaited,
    // because it ends by awaiting a dialog nothing dismisses here.
    await tester.runAsync(() async {
      unawaited(reportPreviousPortableUpdate(navigator));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    // Bounded pumps rather than pumpAndSettle: the report is parked on its
    // dialog, which nothing pops, so "settled" is never reached.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('says nothing when no update was handed over', (tester) async {
    await tester.runAsync(() async {
      await AppPaths.init(exeDirOverride: root);
    });

    await report(tester);

    expect(find.byType(AlertDialog), findsNothing);
  }, skip: _skipOffWindows);

  testWidgets('confirms an update that landed', (tester) async {
    final package = await seedHandoff(tester, toVersion: '2.1.0');
    PackageInfo.setMockInitialValues(
      appName: 'IRIS',
      packageName: 'com.iris',
      version: '2.1.0',
      buildNumber: '1',
      buildSignature: '',
    );

    await report(tester);

    expect(find.text(t.update_report_applied_title), findsOneWidget);
    expect(find.text(t.update_report_applied_body('2.1.0')), findsOneWidget);
    // The package did its job; nothing keeps it around.
    expect(package.existsSync(), isFalse);
    // And the note is consumed: the next launch has nothing to report.
    // (Checked on disk rather than through the async reader: real file I/O does
    // not settle on the test's fake event loop.)
    expect(
      File(p.join(updates.path, pendingUpdateFileName)).existsSync(),
      isFalse,
    );
  }, skip: _skipOffWindows);

  testWidgets('a version without its trailing segment still counts as landed',
      (tester) async {
    // `2.1` and `2.1.0` are the same release. A raw string equality read them
    // as different and reported a FINISHED update as "did not finish" forever.
    final package = await seedHandoff(tester, toVersion: '2.1.0');
    PackageInfo.setMockInitialValues(
      appName: 'IRIS',
      packageName: 'com.iris',
      version: '2.1',
      buildNumber: '1',
      buildSignature: '',
    );

    await report(tester);

    expect(find.text(t.update_report_applied_title), findsOneWidget);
    expect(find.text(t.update_report_incomplete_title), findsNothing);
    expect(package.existsSync(), isFalse);
  }, skip: _skipOffWindows);

  testWidgets('reports an update that did not land, package kept',
      (tester) async {    final package = await seedHandoff(tester, toVersion: '2.1.0');
    PackageInfo.setMockInitialValues(
      appName: 'IRIS',
      packageName: 'com.iris',
      version: '2.0.7',
      buildNumber: '1',
      buildSignature: '',
    );

    await report(tester);

    expect(find.text(t.update_report_incomplete_title), findsOneWidget);
    expect(
      find.text(t.update_report_incomplete_body('2.1.0', updates.path)),
      findsOneWidget,
    );
    // Kept on purpose: this is what a manual run of the updater needs.
    expect(package.existsSync(), isTrue);
  }, skip: _skipOffWindows);

  testWidgets('a corrupt record is dropped instead of being read forever',
      (tester) async {
    await tester.runAsync(() async {
      await AppPaths.init(exeDirOverride: root);
      updates = Directory(p.join(root.path, AppPaths.userDataDirName, 'updates'))
        ..createSync(recursive: true);
      // A truncated write from a power loss mid-record.
      File(p.join(updates.path, pendingUpdateFileName))
          .writeAsStringSync('{"from":"2.0.7","to":');
    });

    await report(tester);

    // Nothing could ever report it, and the alternative is re-reading a broken
    // file on every single launch.
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      File(p.join(updates.path, pendingUpdateFileName)).existsSync(),
      isFalse,
      reason: 'the unreadable record is discarded',
    );
  }, skip: _skipOffWindows);
}
