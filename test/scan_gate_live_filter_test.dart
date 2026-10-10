import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/actions/scan_play_gate.dart';

void main() {
  group('filterLiveScanRoots', () {
    test('drops live roots, keeps actionable ones', () {
      final dirs = const [
        (storageId: 'a', path: 'A', recursive: true),
        (storageId: 'b', path: 'B', recursive: true),
      ];
      final out = filterLiveScanRoots(dirs, (d) => d.storageId == 'b');
      expect(out.map((e) => e.storageId), ['a']);
    });

    test('all live filters to empty', () {
      final dirs = const [
        (storageId: 'b', path: 'B', recursive: true),
      ];
      expect(filterLiveScanRoots(dirs, (_) => true), isEmpty);
    });

    test('a live root on the same storage does not hide a SIBLING root', () {
      // The store is single-flight but scans one root set; D:/A being scanned
      // must not make D:/B look live (that silently skipped its scan-now).
      final dirs = const [
        (storageId: 'd', path: 'D:/A', recursive: true),
        (storageId: 'd', path: 'D:/B', recursive: true),
      ];
      final out = filterLiveScanRoots(
        dirs,
        (dir) => isScanLiveForState(
          isScanning: true,
          runningStorageId: 'd',
          runningRoots: const ['D:/A'],
          storageId: dir.storageId,
          root: dir.path,
        ),
      );
      expect(out.map((e) => e.path), ['D:/B']);
    });
  });

  group('isScanLiveForState', () {
    test('false when store is not scanning', () {
      expect(
        isScanLiveForState(
          isScanning: false,
          runningStorageId: 'b',
          runningRoots: const ['B'],
          storageId: 'b',
          root: 'B',
        ),
        isFalse,
      );
    });

    test('false when running storage is null (transient reset)', () {
      expect(
        isScanLiveForState(
          isScanning: true,
          runningStorageId: null,
          runningRoots: const ['B'],
          storageId: 'b',
          root: 'B',
        ),
        isFalse,
      );
    });

    test('false when no running roots are recorded yet', () {
      expect(
        isScanLiveForState(
          isScanning: true,
          runningStorageId: 'b',
          runningRoots: const [],
          storageId: 'b',
          root: 'B',
        ),
        isFalse,
      );
    });

    test('true for the running storage AND a covered root', () {
      expect(
        isScanLiveForState(
          isScanning: true,
          runningStorageId: 'd',
          runningRoots: const ['D:/A'],
          storageId: 'd',
          root: 'D:/A',
        ),
        isTrue,
      );
      // A descendant of the running root is being scanned too.
      expect(
        isScanLiveForState(
          isScanning: true,
          runningStorageId: 'd',
          runningRoots: const ['D:/A'],
          storageId: 'd',
          root: 'D:/A/sub',
        ),
        isTrue,
      );
    });

    test('false for a sibling root on the same storage', () {
      expect(
        isScanLiveForState(
          isScanning: true,
          runningStorageId: 'd',
          runningRoots: const ['D:/A'],
          storageId: 'd',
          root: 'D:/B',
        ),
        isFalse,
      );
    });

    test('false for a different storage', () {
      expect(
        isScanLiveForState(
          isScanning: true,
          runningStorageId: 'b',
          runningRoots: const ['B'],
          storageId: 'a',
          root: 'B',
        ),
        isFalse,
      );
    });
  });
}
