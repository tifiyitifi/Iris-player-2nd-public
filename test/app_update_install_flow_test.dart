import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/services/update_handoff.dart';
import 'package:iris/features/app_update/services/update_installer.dart';
import 'package:iris/features/app_update/services/windows_update_plan.dart';
import 'package:iris/features/app_update/view/update_flow.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

/// A file that starts like a ZIP archive (the local-file-header magic), which
/// is all the app-side pre-flight looks at.
const _zipHeader = <int>[0x50, 0x4B, 0x03, 0x04, 0x14, 0x00];

UpdateAvailable _available({required bool portable}) => UpdateAvailable(
      tag: 'v2.1.0',
      version: '2.1.0',
      pageUrl: 'https://example.invalid/releases/tag/v2.1.0',
      notes: '',
      platform: UpdatePlatform.windows,
      asset: const ReleaseAsset(
        name: 'IRIS-windows-v2.1.0.zip',
        downloadUrl: 'https://example.invalid/pkg.zip',
        size: 1000,
      ),
      portable: portable,
    );

void main() {
  late AppLocalizations t;
  late Directory root;

  setUpAll(() async {
    t = await AppLocalizations.delegate.load(const Locale('en'));
    // The flow reads the running version before it records the hand-off.
    PackageInfo.setMockInitialValues(
      appName: 'IRIS',
      packageName: 'com.iris',
      version: '2.0.7',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('iris-handoff-test');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File packageInRoot() {
    return File(p.join(root.path, 'IRIS-windows-v2.1.0.zip'))
      ..writeAsBytesSync(_zipHeader);
  }

  /// Mounts a host page and hands [package] over from it, exactly as the
  /// release dialog does.
  ///
  /// The flow is driven directly rather than through a tap, and inside
  /// [WidgetTester.runAsync]: the hand-off is real file I/O, and file I/O does
  /// not progress inside the fake-async zone a widget test otherwise runs in.
  Future<void> mount(
    WidgetTester tester,
    UpdateAvailable result,
    File package,
    WindowsUpdateEnvironment windows, {
    int expectedSize = 0,
    String? expectedSha256,
  }) async {
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              pageContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Not awaited: when the hand-off is refused it ends by awaiting a dialog,
    // which nothing dismisses here — awaiting it would hang the test. Started
    // inside [WidgetTester.runAsync] so its file I/O runs on the real event
    // loop rather than the test's fake one, which never completes it.
    await tester.runAsync(() async {
      unawaited(
        handOffUpdatePackage(
          pageContext,
          result,
          package,
          expectedSize: expectedSize,
          expectedSha256: expectedSha256,
          windows: windows,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('a ready portable build is handed over, recorded, then shuts down',
      (tester) async {
    File(p.join(root.path, portableUpdaterScriptName)).writeAsStringSync('script');
    final package = packageInRoot();

    final events = <String>[];
    PendingUpdate? recordAtLaunch;
    var shutDown = false;

    final windows = WindowsUpdateEnvironment(
      // The real pre-flight, pointed at this test's folder instead of the real
      // installation.
      plan: ({
        required bool portable,
        required File package,
        required String exeDir,
      }) =>
          planWindowsUpdate(
        portable: portable,
        package: package,
        exeDir: root.path,
      ),
      launchPortable: ({
        required String scriptPath,
        required File zip,
        required String? logPath,
      }) async {
        events.add('launch');
        // Read INSIDE the launch, so this is what was on disk at hand-over time.
        recordAtLaunch = await readPendingUpdate(p.dirname(zip.path));
        expect(scriptPath, p.join(root.path, portableUpdaterScriptName));
        expect(zip.path, package.path);
        expect(logPath, isNotNull);
      },
      recordPending: ({
        required String workDir,
        required String fromVersion,
        required String toVersion,
        required String packagePath,
      }) async {
        events.add('record');
        await recordPendingUpdate(
          workDir: workDir,
          fromVersion: fromVersion,
          toVersion: toVersion,
          packagePath: packagePath,
        );
      },
      shutdown: () async {
        events.add('shutdown');
        shutDown = true;
      },
      launchInstaller: (File installer) async =>
          fail('the installer must not run for a portable build'),
    );

    await mount(tester, _available(portable: true), package, windows);

    // The record is what the NEXT launch reads back, so it has to be on disk
    // before the app is gone.
    expect(recordAtLaunch, isNotNull);
    expect(recordAtLaunch!.toVersion, '2.1.0');
    expect(recordAtLaunch!.fromVersion, '2.0.7');
    expect(events, ['record', 'launch', 'shutdown']);
    expect(shutDown, isTrue);
  });

  testWidgets('a hand-off that cannot start drops its record again',
      (tester) async {
    File(p.join(root.path, portableUpdaterScriptName)).writeAsStringSync('script');
    final package = packageInRoot();

    final events = <String>[];
    PendingUpdate? pendingAfterFailure;
    var shutDown = false;

    final windows = WindowsUpdateEnvironment(
      plan: ({
        required bool portable,
        required File package,
        required String exeDir,
      }) =>
          planWindowsUpdate(
        portable: portable,
        package: package,
        exeDir: root.path,
      ),
      launchPortable: ({
        required String scriptPath,
        required File zip,
        required String? logPath,
      }) async {
        events.add('launch');
        // The launcher cannot start the updater.
        throw const UpdateInstallException(InstallFailure.cannotLaunch);
      },
      recordPending: ({
        required String workDir,
        required String fromVersion,
        required String toVersion,
        required String packagePath,
      }) async {
        events.add('record');
        await recordPendingUpdate(
          workDir: workDir,
          fromVersion: fromVersion,
          toVersion: toVersion,
          packagePath: packagePath,
        );
      },
      clearPending: ({required String workDir}) async {
        events.add('clear');
        await clearPendingUpdate(workDir: workDir);
        pendingAfterFailure = await readPendingUpdate(workDir);
      },
      shutdown: () async {
        events.add('shutdown');
        shutDown = true;
      },
    );

    await mount(tester, _available(portable: true), package, windows);

    // Recorded then dropped: a record that outlived a hand-off which never
    // happened would greet the next launch with "the last update did not
    // finish" for a run that never began.
    expect(events, ['record', 'launch', 'clear']);
    expect(pendingAfterFailure, isNull);
    // Nothing was applied, so the app is still here.
    expect(shutDown, isFalse);
    expect(find.text(t.update_install_failed), findsOneWidget);
  });

  testWidgets('a blocked hand-off stays open and says why', (tester) async {
    // No updater script next to the executable: the pre-flight has to refuse.
    final package = packageInRoot();

    var launched = false;
    var shutDown = false;
    final windows = WindowsUpdateEnvironment(
      plan: ({
        required bool portable,
        required File package,
        required String exeDir,
      }) =>
          planWindowsUpdate(
        portable: portable,
        package: package,
        exeDir: root.path,
      ),
      launchPortable: ({
        required String scriptPath,
        required File zip,
        required String? logPath,
      }) async =>
          launched = true,
      shutdown: () async => shutDown = true,
    );

    await mount(tester, _available(portable: true), package, windows);

    // The whole point of the fix: nothing was applied, so the app is still here
    // and the user is told what to do about it.
    expect(launched, isFalse);
    expect(shutDown, isFalse);
    expect(find.text(t.update_portable_blocked_title), findsOneWidget);
    expect(
      find.text(t.update_portable_blocked_updater_missing),
      findsOneWidget,
    );
  });

  testWidgets('an unusable package is refused and cleaned up', (tester) async {
    File(p.join(root.path, portableUpdaterScriptName)).writeAsStringSync('script');
    // A proxy error page saved under the package's name.
    final package = File(p.join(root.path, 'IRIS-windows-v2.1.0.zip'))
      ..writeAsStringSync('<html>rate limited</html>');

    var launched = false;
    var shutDown = false;
    final windows = WindowsUpdateEnvironment(
      plan: ({
        required bool portable,
        required File package,
        required String exeDir,
      }) =>
          planWindowsUpdate(
        portable: portable,
        package: package,
        exeDir: root.path,
      ),
      launchPortable: ({
        required String scriptPath,
        required File zip,
        required String? logPath,
      }) async =>
          launched = true,
      shutdown: () async => shutDown = true,
    );

    await mount(tester, _available(portable: true), package, windows);

    expect(launched, isFalse);
    expect(shutDown, isFalse);
    expect(
      find.text(t.update_portable_blocked_package_unusable),
      findsOneWidget,
    );
    // Deleted rather than left for an updater to find: a refused package must
    // not survive as something that could be installed later.
    expect(package.existsSync(), isFalse);
  });

  testWidgets('the installed edition runs its installer instead', (tester) async {
    final package = File(p.join(root.path, 'IRIS-windows-installer-v2.1.0.exe'))
      ..writeAsStringSync('MZ');

    final events = <String>[];
    final windows = WindowsUpdateEnvironment(
      plan: ({
        required bool portable,
        required File package,
        required String exeDir,
      }) =>
          planWindowsUpdate(
        portable: portable,
        package: package,
        exeDir: root.path,
      ),
      launchInstaller: (File installer) async => events.add('installer'),
      shutdown: () async => events.add('shutdown'),
    );

    await mount(tester, _available(portable: false), package, windows);

    expect(events, ['installer', 'shutdown']);
    expect(find.text(t.update_portable_blocked_title), findsNothing);
  });

  testWidgets('a package swapped after the download is refused, not installed',
      (tester) async {
    // The transfer verified 1000 bytes; the file on disk no longer matches it.
    // Nothing may be handed to an installer in that state.
    final package = packageInRoot();
    expect(package.lengthSync(), isNot(1000));

    var launched = false;
    var shutDown = false;
    final windows = WindowsUpdateEnvironment(
      plan: ({
        required bool portable,
        required File package,
        required String exeDir,
      }) =>
          planWindowsUpdate(
        portable: portable,
        package: package,
        exeDir: root.path,
      ),
      launchInstaller: (File installer) async => launched = true,
      shutdown: () async => shutDown = true,
    );

    await mount(
      tester,
      _available(portable: false),
      package,
      windows,
      expectedSize: 1000,
    );

    expect(launched, isFalse);
    expect(shutDown, isFalse);
    expect(find.text(t.update_handoff_integrity_failed), findsOneWidget);
    // The mismatched file is deleted rather than left for a later install.
    expect(package.existsSync(), isFalse);
  });
}
