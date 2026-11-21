import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The gate is a PowerShell checker driven by git hooks. This suite runs it
/// against throwaway repositories so the real working tree is never touched.
/// Every sample is assembled at run time: this file must itself pass the gate.
const _backslash = r'\';
const _slash = '/';
// PowerShell error text can arrive in the system code page; decode leniently
// so a checker crash reports as a failed expectation instead of an exception.
const _utf8 = Utf8Codec(allowMalformed: true);

String? _findPowerShell() {
  if (!Platform.isWindows) return null;
  for (final name in <String>['powershell', 'pwsh']) {
    final result = Process.runSync(
      name,
      <String>['-NoProfile', '-Command', 'exit 0'],
    );
    if (result.exitCode == 0) return name;
  }
  return null;
}

final String? _powershell = _findPowerShell();
final String _checker = File('scripts/check-local-paths.ps1').absolute.path;

String _drive(String letter, [List<String> parts = const <String>[]]) {
  final buffer = StringBuffer('$letter:');
  for (final part in parts) {
    buffer.write(_backslash);
    buffer.write(part);
  }
  return buffer.toString();
}

String _runGit(String repo, List<String> args) {
  final result = Process.runSync(
    'git',
    args,
    workingDirectory: repo,
    stdoutEncoding: _utf8,
    stderrEncoding: _utf8,
  );
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

ProcessResult _runCheck(
  String repo, {
  List<String> args = const <String>[],
  Map<String, String> env = const <String, String>{},
}) {
  return Process.runSync(
    _powershell!,
    <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      _checker,
      '-Root',
      repo,
      ...args,
    ],
    workingDirectory: repo,
    environment: <String, String>{...Platform.environment, ...env},
    stdoutEncoding: _utf8,
    stderrEncoding: _utf8,
  );
}

String _output(ProcessResult result) => '${result.stdout}${result.stderr}';

String _readVersion(String repo) =>
    File('$repo/android/version.properties').readAsStringSync().trim();

void _copyDirectory(String source, String destination) {
  Directory(destination).createSync(recursive: true);
  for (final entity in Directory(source).listSync(recursive: true)) {
    final relative = entity.path
        .substring(source.length + 1)
        .replaceAll(_backslash, _slash);
    final target = '$destination/$relative';
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      File(target).parent.createSync(recursive: true);
      entity.copySync(target);
    }
  }
}

/// Copies the real hooks and the checker into the throwaway repository, so a
/// test can exercise the wiring (sh -> PowerShell) instead of the checker only.
void _installHooks(String repo) {
  _copyDirectory('.githooks', '$repo/.githooks');
  Directory('$repo/scripts').createSync(recursive: true);
  for (final name in <String>[
    'local-gate.sh',
    'check-local-paths.ps1',
    'sync-version-code.sh',
  ]) {
    File('scripts/$name').copySync('$repo/scripts/$name');
  }
  _runGit(repo, <String>['config', 'core.hooksPath', '.githooks']);
}

Directory _createRepo() {
  final repo = Directory.systemTemp.createTempSync('iris-local-gate-');
  _runGit(repo.path, <String>['init', '-q']);
  _runGit(repo.path, <String>['config', 'user.email', 'test@example.com']);
  _runGit(repo.path, <String>['config', 'user.name', 'test']);
  _runGit(repo.path, <String>['config', 'commit.gpgsign', 'false']);
  _runGit(repo.path, <String>['config', 'core.autocrlf', 'false']);
  return repo;
}

void main() {
  group(
    'local privacy gate',
    () {
      late Directory repo;

      setUp(() {
        repo = _createRepo();
      });

      tearDown(() {
        if (repo.existsSync()) {
          repo.deleteSync(recursive: true);
        }
      });

      test(
          'passes a staged stand-in path and warns about the missing deny list',
          () {
        File('${repo.path}/note.md').writeAsStringSync(
          'clip at ${_drive('C', <String>['work', 'inbox', 'a.mp4'])}\n',
        );
        _runGit(repo.path, <String>['add', 'note.md']);

        final result = _runCheck(repo.path);

        expect(result.exitCode, 0, reason: _output(result));
        expect(_output(result), contains('deny list not found'));
      });

      test('rejects a staged real-looking local path', () {
        File('${repo.path}/note.md').writeAsStringSync(
          'clip at ${_drive('C', <String>[
                'Users',
                'someone',
                'Videos',
                'a.mp4'
              ])}\n',
        );
        _runGit(repo.path, <String>['add', 'note.md']);

        final result = _runCheck(repo.path);

        expect(result.exitCode, 1, reason: _output(result));
        expect(_output(result), contains('local path'));
      });

      test('rejects the machine profile even under a stand-in root', () {
        final profile = _drive('C', <String>['work', 'gate-profile']);
        File('${repo.path}/note.md').writeAsStringSync(
          'clip at $profile${_backslash}videos${_backslash}a.mp4\n',
        );
        _runGit(repo.path, <String>['add', 'note.md']);

        final result = _runCheck(
          repo.path,
          env: <String, String>{'USERPROFILE': profile, 'HOME': profile},
        );

        expect(result.exitCode, 1, reason: _output(result));
        expect(_output(result), contains('local machine path'));
      });

      test('allows the documented user placeholders', () {
        File('${repo.path}/note.md').writeAsStringSync(
          'a ${_drive('C', <String>['Users', 'Some Name', 'iris', 'a.bin'])}\n'
          'b ${_drive('C', <String>['Users', '<user>', 'AppData', 'a.bin'])}\n',
        );
        _runGit(repo.path, <String>['add', 'note.md']);

        final result = _runCheck(repo.path);

        expect(result.exitCode, 0, reason: _output(result));
      });

      test('allows a bare drive root and the documented nested-drive shape',
          () {
        final nested = '${_drive('D')}$_slash' 'd:$_slash' 'Movies/a.mp4';
        File('${repo.path}/note.md').writeAsStringSync(
          'a ${_drive('D')}$_backslash\n'
          'b $nested\n',
        );
        _runGit(repo.path, <String>['add', 'note.md']);

        final result = _runCheck(repo.path);

        expect(result.exitCode, 0, reason: _output(result));
      });

      test('rejects a private term from the deny list', () {
        final denyDir = Directory('${repo.path}/.local_privacy')
          ..createSync(recursive: true);
        File('${denyDir.path}/deny-list.txt')
            .writeAsStringSync('SecretProject\n');
        File('${repo.path}/note.md')
            .writeAsStringSync('the SecretProject folder\n');
        _runGit(repo.path, <String>['add', 'note.md']);

        final result = _runCheck(repo.path);

        expect(result.exitCode, 1, reason: _output(result));
        expect(_output(result), contains('private term'));
      });

      test('rejects a local path in the commit message', () {
        File('${repo.path}/.git/COMMIT_EDITMSG').writeAsStringSync(
          'subject ${_drive('C', <String>['Users', 'someone', 'a.mp4'])}\n',
        );

        final result = _runCheck(repo.path, args: <String>['-Message']);

        expect(result.exitCode, 1, reason: _output(result));
        expect(_output(result), contains('the commit message'));
      });

      test('checks the exact push range', () {
        File('${repo.path}/a.md').writeAsStringSync('one\n');
        _runGit(repo.path, <String>['add', 'a.md']);
        _runGit(repo.path, <String>['commit', '-q', '-m', 'one']);
        final first = _runGit(repo.path, <String>['rev-parse', 'HEAD']);

        File('${repo.path}/b.md').writeAsStringSync(
          'two ${_drive('C', <String>['Users', 'someone', 'b.mp4'])}\n',
        );
        _runGit(repo.path, <String>['add', 'b.md']);
        _runGit(repo.path, <String>['commit', '-q', '-m', 'two']);
        final second = _runGit(repo.path, <String>['rev-parse', 'HEAD']);

        final result = _runCheck(
          repo.path,
          args: <String>['-Pushed', '-Range', '$first..$second'],
        );

        expect(result.exitCode, 1, reason: _output(result));
        expect(_output(result), contains('local path'));
      });

      test('warns instead of failing for a path that is already committed', () {
        File('${repo.path}/a.md').writeAsStringSync(
          'one ${_drive('D', <String>['personal', 'a.mp4'])}\n',
        );
        _runGit(repo.path, <String>['add', 'a.md']);
        _runGit(repo.path, <String>['commit', '-q', '-m', 'one']);

        final result = _runCheck(repo.path, args: <String>['-All']);

        expect(result.exitCode, 0, reason: _output(result));
        expect(_output(result), contains('warning:'));
      });

      test('rejects a local data file by name', () {
        File('${repo.path}/a.sqlite').writeAsStringSync('x\n');
        _runGit(repo.path, <String>['add', 'a.sqlite']);

        final result = _runCheck(repo.path);

        expect(result.exitCode, 1, reason: _output(result));
        expect(_output(result), contains('local data in a file name'));
      });

      test('rejects a URL that carries credentials', () {
        final scheme = 'https';
        final user = 'u';
        final pass = 'p';
        final host = 'example.com';
        final url = '$scheme:$_slash$_slash$user:$pass@$host/a';
        File('${repo.path}/note.md').writeAsStringSync('server $url\n');
        _runGit(repo.path, <String>['add', 'note.md']);

        final result = _runCheck(repo.path);

        expect(result.exitCode, 1, reason: _output(result));
        expect(_output(result), contains('credential URL'));
      });

      test('flags a real title and episode in prose but not in tests', () {
        final title = String.fromCharCodes(
          <int>[0x8fdb, 0x51fb, 0x7684, 0x5de8, 0x4eba],
        );
        final episode =
            '$title ${String.fromCharCode(0x7b2c)}1${String.fromCharCode(0x96c6)}';

        File('${repo.path}/CHANGELOG.md').writeAsStringSync('$episode\n');
        _runGit(repo.path, <String>['add', 'CHANGELOG.md']);
        final prose = _runCheck(repo.path);
        expect(prose.exitCode, 1, reason: _output(prose));
        expect(_output(prose), contains('real title and episode'));

        _runGit(repo.path, <String>['reset', '-q']);
        File('${repo.path}/CHANGELOG.md').deleteSync();
        Directory('${repo.path}/test').createSync();
        File('${repo.path}/test/fixture_test.dart')
            .writeAsStringSync('$episode\n');
        _runGit(repo.path, <String>['add', 'test/fixture_test.dart']);

        final testFile = _runCheck(repo.path);
        expect(testFile.exitCode, 0, reason: _output(testFile));
      });

      test('reports its own broken input as exit code 2, not a clean tree', () {
        final result = _runCheck(
          repo.path,
          args: <String>['-Pushed', '-Range', 'not-a-range'],
        );

        expect(result.exitCode, 2, reason: _output(result));
        expect(_output(result), contains('invalid push range'));
      });

      test('rejects a merge message handed to commit-msg', () {
        File('${repo.path}/.git/MERGE_MSG').writeAsStringSync(
          'merge ${_drive('C', <String>['Users', 'someone', 'a.mp4'])}\n',
        );

        final result = _runCheck(
          repo.path,
          args: <String>['-Message', '-MessageFile', '.git/MERGE_MSG'],
        );

        expect(result.exitCode, 1, reason: _output(result));
        expect(_output(result), contains('the commit message'));
      });

      test('checks the messages of the pushed commits', () {
        File('${repo.path}/a.md').writeAsStringSync('one\n');
        _runGit(repo.path, <String>['add', 'a.md']);
        _runGit(repo.path, <String>['commit', '-q', '-m', 'one']);
        final first = _runGit(repo.path, <String>['rev-parse', 'HEAD']);

        _runGit(repo.path, <String>[
          'commit',
          '--allow-empty',
          '-q',
          '-m',
          'secret ${_drive('C', <String>['Users', 'someone', 'b.mp4'])}',
        ]);
        final second = _runGit(repo.path, <String>['rev-parse', 'HEAD']);

        final result = _runCheck(
          repo.path,
          args: <String>['-Pushed', '-Range', '$first..$second'],
        );

        expect(result.exitCode, 1, reason: _output(result));
        expect(_output(result), contains('pushed commit message'));
      });

      test('catches a path added and removed inside the pushed range', () {
        File('${repo.path}/a.md').writeAsStringSync('one\n');
        _runGit(repo.path, <String>['add', 'a.md']);
        _runGit(repo.path, <String>['commit', '-q', '-m', 'one']);
        final first = _runGit(repo.path, <String>['rev-parse', 'HEAD']);

        File('${repo.path}/leak.md').writeAsStringSync(
          'x ${_drive('C', <String>['Users', 'someone', 'b.mp4'])}\n',
        );
        _runGit(repo.path, <String>['add', 'leak.md']);
        _runGit(repo.path, <String>['commit', '-q', '-m', 'add']);
        _runGit(repo.path, <String>['rm', '-q', 'leak.md']);
        _runGit(repo.path, <String>['commit', '-q', '-m', 'remove']);
        final second = _runGit(repo.path, <String>['rev-parse', 'HEAD']);

        final result = _runCheck(
          repo.path,
          args: <String>['-Pushed', '-Range', '$first..$second'],
        );

        expect(result.exitCode, 1, reason: _output(result));
        expect(_output(result), contains('local path'));
      });

      test('reports a private term on a line that also holds a path', () {
        File('${repo.path}/.gitignore').writeAsStringSync('.local_privacy/\n');
        final denyDir = Directory('${repo.path}/.local_privacy')
          ..createSync(recursive: true);
        File('${denyDir.path}/deny-list.txt')
            .writeAsStringSync('SecretProject\n');
        File('${repo.path}/leak.md').writeAsStringSync(
          'x ${_drive('D', <String>['personal', 'a.mp4'])} SecretProject\n',
        );
        _runGit(repo.path, <String>['add', '.gitignore', 'leak.md']);
        _runGit(repo.path, <String>['commit', '-q', '-m', 'seed']);

        final result = _runCheck(repo.path, args: <String>['-All']);

        expect(result.exitCode, 1, reason: _output(result));
        expect(_output(result), contains('private term'));
      });

      test('flags a real title and episode without a space', () {
        final title = String.fromCharCodes(
          <int>[0x793a, 0x4f8b, 0x6807, 0x9898, 0x6587, 0x5b57],
        );
        final episode =
            '$title${String.fromCharCode(0x7b2c)}1${String.fromCharCode(0x96c6)}';
        File('${repo.path}/CHANGELOG.md').writeAsStringSync('$episode\n');
        _runGit(repo.path, <String>['add', 'CHANGELOG.md']);

        final result = _runCheck(repo.path);

        expect(result.exitCode, 1, reason: _output(result));
        expect(_output(result), contains('real title and episode'));
      });

      test('does not flag a navigation phrase as a title', () {
        final navigation = String.fromCharCodes(
          <int>[0x7acb, 0x5373, 0x8df3, 0x5230],
        );
        final phrase =
            '$navigation${String.fromCharCode(0x7b2c)}2${String.fromCharCode(0x96c6)}';
        File('${repo.path}/CHANGELOG.md').writeAsStringSync('$phrase\n');
        _runGit(repo.path, <String>['add', 'CHANGELOG.md']);

        final result = _runCheck(repo.path);

        expect(result.exitCode, 0, reason: _output(result));
      });

      test('rejects an SMB URL that carries credentials', () {
        final url = 'smb:$_slash$_slash' 'u:p@example.com/a';
        File('${repo.path}/note.md').writeAsStringSync('server $url\n');
        _runGit(repo.path, <String>['add', 'note.md']);

        final result = _runCheck(repo.path);

        expect(result.exitCode, 1, reason: _output(result));
        expect(_output(result), contains('credential URL'));
      });

      test('a rejected commit message does not burn versionCode', () {
        _installHooks(repo.path);
        Directory('${repo.path}/android').createSync();
        File('${repo.path}/android/version.properties')
            .writeAsStringSync('versionCode=100\n');
        File('${repo.path}/pubspec.yaml')
            .writeAsStringSync('name: iris\nversion: 2.1.0+100\n');
        File('${repo.path}/a.txt').writeAsStringSync('ok\n');
        _runGit(repo.path, <String>['add', '-A']);
        _runGit(repo.path, <String>['commit', '-q', '-m', 'base']);
        expect(_readVersion(repo.path), 'versionCode=101');

        final headBefore = _runGit(repo.path, <String>['rev-parse', 'HEAD']);
        final rejected = Process.runSync(
          'git',
          <String>[
            'commit',
            '--allow-empty',
            '-m',
            'bad ${_drive('C', <String>['Users', 'someone', 'x.mp4'])}',
          ],
          workingDirectory: repo.path,
          stdoutEncoding: _utf8,
          stderrEncoding: _utf8,
        );
        expect(rejected.exitCode, isNot(0), reason: _output(rejected));
        expect(
          _runGit(repo.path, <String>['rev-parse', 'HEAD']),
          headBefore,
          reason: 'the rejected commit must not exist',
        );

        _runGit(
          repo.path,
          <String>['commit', '--allow-empty', '-q', '-m', 'good'],
        );
        expect(_readVersion(repo.path), 'versionCode=102');
        expect(
          _runGit(
            repo.path,
            <String>['show', 'HEAD:android/version.properties'],
          ).trim(),
          'versionCode=102',
        );
      });
    },
    skip: _powershell == null ? 'PowerShell not found' : false,
  );
}
