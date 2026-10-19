import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/services/update_handoff.dart';
import 'package:iris/features/app_update/services/update_installer.dart';
import 'package:iris/features/app_update/services/windows_update_plan.dart';
import 'package:path/path.dart' as p;

/// A minimal file that starts like a ZIP archive (the local-file-header magic).
List<int> _zipMagic() => const <int>[0x50, 0x4B, 0x03, 0x04, 0x14, 0x00];

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('iris-update-test');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File writeZip(String name) {
    final file = File(p.join(root.path, name))..createSync();
    file.writeAsBytesSync(_zipMagic());
    return file;
  }

  group('portable updater command', () {
    test('is launched through cmd start, so powershell gets a console', () {
      final command = portableUpdaterCommand(
        scriptPath: r'C:\iris\portable_update_by_zip.ps1',
        zipPath: r'C:\iris\updates\IRIS-windows-v2.1.0.zip',
        logPath: r'C:\iris\updates\portable-update-1.log',
      )!;

      // A console application launched with DETACHED_PROCESS straight from this
      // GUI process gets no console at all, and Windows PowerShell then exits
      // without running a single line of the script: the hand-off was a silent
      // no-op, which is exactly what "it just closes" was. `start` allocates a
      // console for the script.
      expect(command.executable, 'cmd.exe');
      expect(command.arguments.take(3), ['/c', 'start', portableUpdaterTitle]);
      expect(command.arguments[3], 'powershell.exe');
      expect(
        command.arguments,
        containsAllInOrder([
          '-File',
          r'C:\iris\portable_update_by_zip.ps1',
          '-ZipPath',
          r'C:\iris\updates\IRIS-windows-v2.1.0.zip',
        ]),
      );
      expect(
        command.arguments,
        containsAllInOrder(['-LogPath', r'C:\iris\updates\portable-update-1.log']),
      );
      expect(command.arguments.last, '-NonInteractive');
    });

    test('omits the log argument when there is no log path', () {
      final command = portableUpdaterCommand(
        scriptPath: 'script.ps1',
        zipPath: 'pkg.zip',
        logPath: null,
      )!;
      expect(command.arguments, isNot(contains('-LogPath')));
    });

    test('a path cmd.exe would expand is refused, not launched', () {
      // `%`, `!`, `&`, `^`, `(`, `)`, `|`, `<`, `>` and `"` are re-read by the
      // command interpreter after Process.start has already quoted the argument,
      // so the hand-off cannot be made unambiguous — and `start` even reads the
      // first quoted token as a window TITLE.
      for (final char in <String>['%', '!', '&', '^', '(', ')', '|', '<', '>']) {
        expect(isCmdSafePortableUpdaterPath(r'C:\Users\A' + char + r'\iris'), isFalse,
            reason: 'char="$char"');
        expect(
          portableUpdaterCommand(
            scriptPath: r'C:\iris\portable_update_by_zip.ps1',
            zipPath: r'C:\Users\A' + char + r'\IRIS-windows-v2.1.0.zip',
            logPath: null,
          ),
          isNull,
          reason: 'char="$char" must refuse the hand-off',
        );
      }
      // An ordinary path is untouched (incl. the space a profile can hold).
      expect(isCmdSafePortableUpdaterPath(r'C:\Users\Some Name\iris'), isTrue);
      expect(isCmdSafePortableUpdaterPath(''), isFalse);
      expect(
        portableUpdaterCommand(
          scriptPath: r'C:\Users\Some Name\iris\portable_update_by_zip.ps1',
          zipPath: r'C:\Users\Some Name\iris\updates\pkg.zip',
          logPath: null,
        ),
        isNotNull,
      );
    });
  });

  group('planWindowsUpdate', () {
    test('runs the portable updater when the build is portable and ready',
        () async {
      File(p.join(root.path, portableUpdaterScriptName)).writeAsStringSync('');
      final package = writeZip('IRIS-windows-v2.1.0.zip');

      final plan = await planWindowsUpdate(
        portable: true,
        package: package,
        exeDir: root.path,
      );

      expect(plan, isA<PortableSelfUpdate>());
      final portable = plan as PortableSelfUpdate;
      expect(portable.scriptPath, p.join(root.path, portableUpdaterScriptName));
      expect(portable.packagePath, package.path);
      // The log lands next to the package: the user is never left guessing.
      expect(portable.logPath, isNotNull);
      // One STABLE name: a log per timestamp left a file behind for every
      // attempt, in a folder nothing cleans.
      expect(p.basename(portable.logPath), 'portable-update.log');
      expect(p.dirname(portable.logPath), package.parent.path);
      // The log lands next to the package: the user is never left guessing.
      expect(p.dirname(portable.logPath), package.parent.path);
      expect(p.basename(portable.logPath), endsWith('.log'));
    });

    test('two attempts share one log file', () async {
      File(p.join(root.path, portableUpdaterScriptName)).writeAsStringSync('');
      final package = writeZip('IRIS-windows-v2.1.0.zip');

      final first = await planWindowsUpdate(
        portable: true,
        package: package,
        exeDir: root.path,
      ) as PortableSelfUpdate;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final second = await planWindowsUpdate(
        portable: true,
        package: package,
        exeDir: root.path,
      ) as PortableSelfUpdate;

      expect(second.logPath, first.logPath);
    });

    test('refuses before closing the app when the updater is missing',
        () async {
      final package = writeZip('IRIS-windows-v2.1.0.zip');

      final plan = await planWindowsUpdate(
        portable: true,
        package: package,
        exeDir: root.path,
      );

      expect(plan, isA<BlockedUpdate>());
      expect((plan as BlockedUpdate).blocker, WindowsUpdateBlocker.updaterMissing);
    });

    test('refuses a package that is not a ZIP at all', () async {
      File(p.join(root.path, portableUpdaterScriptName)).writeAsStringSync('');
      final package = File(p.join(root.path, 'IRIS-windows-v2.1.0.zip'))
        ..writeAsStringSync('this is an error page, not a package');

      final plan = await planWindowsUpdate(
        portable: true,
        package: package,
        exeDir: root.path,
      );

      expect((plan as BlockedUpdate).blocker, WindowsUpdateBlocker.packageUnusable);
    });

    test('refuses a package that is empty', () async {
      File(p.join(root.path, portableUpdaterScriptName)).writeAsStringSync('');
      final package = File(p.join(root.path, 'IRIS-windows-v2.1.0.zip'))
        ..writeAsBytesSync(const <int>[]);

      final plan = await planWindowsUpdate(
        portable: true,
        package: package,
        exeDir: root.path,
      );

      expect((plan as BlockedUpdate).blocker, WindowsUpdateBlocker.packageUnusable);
    });

    test('falls back to the installer for the installed edition', () async {
      final package = File(p.join(root.path, 'IRIS-windows-installer-v2.1.0.exe'))
        ..writeAsStringSync('MZ');

      final plan = await planWindowsUpdate(
        portable: false,
        package: package,
        exeDir: root.path,
      );

      expect(plan, isA<InstallerUpdate>());
      expect((plan as InstallerUpdate).packagePath, package.path);
    });
  });

  group('hand-off record', () {
    test('round-trips through the updates directory', () async {
      await recordPendingUpdate(
        workDir: root.path,
        fromVersion: '2.0.7',
        toVersion: '2.1.0',
        packagePath: p.join(root.path, 'IRIS-windows-v2.1.0.zip'),
      );

      final record = await readPendingUpdate(root.path);
      expect(record, isNotNull);
      expect(record!.fromVersion, '2.0.7');
      expect(record.toVersion, '2.1.0');
    });

    test('tolerates a corrupt record instead of failing the launch', () async {
      File(p.join(root.path, pendingUpdateFileName)).writeAsStringSync('{not json');
      expect(await readPendingUpdate(root.path), isNull);
    });

    test('reports an applied update once, then clears the record', () async {
      await recordPendingUpdate(
        workDir: root.path,
        fromVersion: '2.0.7',
        toVersion: '2.1.0',
        packagePath: p.join(root.path, 'pkg.zip'),
      );

      final report = await takePreviousUpdateReport(
        workDir: root.path,
        runningVersion: '2.1.0',
      );
      expect(report, isNotNull);
      expect(report!.applied, isTrue);
      expect(report.toVersion, '2.1.0');
      // One-shot: the next launch has nothing to say.
      expect(
        await takePreviousUpdateReport(
          workDir: root.path,
          runningVersion: '2.1.0',
        ),
        isNull,
      );
    });

    test('reports an update that did not land, and keeps the package', () async {
      final package = p.join(root.path, 'IRIS-windows-v2.1.0.zip');
      File(package).writeAsBytesSync(_zipMagic());
      await recordPendingUpdate(
        workDir: root.path,
        fromVersion: '2.0.7',
        toVersion: '2.1.0',
        packagePath: package,
      );

      final report = await takePreviousUpdateReport(
        workDir: root.path,
        runningVersion: '2.0.7',
      );

      expect(report!.applied, isFalse);
      // Kept on purpose: the user can still run the updater by hand.
      expect(File(package).existsSync(), isTrue);
    });

    test('deletes the downloaded package once it has landed', () async {
      final package = p.join(root.path, 'IRIS-windows-v2.1.0.zip');
      File(package).writeAsBytesSync(_zipMagic());
      await recordPendingUpdate(
        workDir: root.path,
        fromVersion: '2.0.7',
        toVersion: '2.1.0',
        packagePath: package,
      );

      await takePreviousUpdateReport(
        workDir: root.path,
        runningVersion: '2.1.0',
      );

      expect(File(package).existsSync(), isFalse);
    });

    test('says nothing when no update was ever handed over', () async {
      expect(
        await takePreviousUpdateReport(
          workDir: root.path,
          runningVersion: '2.1.0',
        ),
        isNull,
      );
    });
  });
}
