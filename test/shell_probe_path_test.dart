@TestOn('windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/probe/windows_shell_probe.dart';

/// Shell probing rejects forward-slash absolute paths outright
/// (SHGetPropertyStoreFromParsingName fails in ~ms with all-empty results),
/// while callers such as the VM duration scan feed `playableUri` output.
/// The probe entry point must normalize drive-letter paths to native
/// separators; every other form passes through untouched.
void main() {
  test('drive-letter forward slashes become native backslashes', () {
    expect(normalizeShellProbePath('E:/vault/003/ani/a.mp4'),
        r'E:\vault\003\ani\a.mp4');
  });

  test('native backslash paths are untouched', () {
    expect(normalizeShellProbePath(r'E:\vault\003\ani\a.mp4'),
        r'E:\vault\003\ani\a.mp4');
  });

  test('forward-slash UNC keeps its accepted form', () {
    expect(normalizeShellProbePath('//server/share/x.mp4'),
        '//server/share/x.mp4');
  });

  test('relative, content and url forms pass through', () {
    expect(normalizeShellProbePath('vault/ani/a.mp4'), 'vault/ani/a.mp4');
    expect(normalizeShellProbePath('content://media/1'), 'content://media/1');
    expect(normalizeShellProbePath('http://host:8080/a.mp4'),
        'http://host:8080/a.mp4');
  });
}
