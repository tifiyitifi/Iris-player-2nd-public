import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/windows/explorer/services/explorer_reveal_service.dart';
import 'package:iris/models/storages/storage.dart';

// Policy under test: the "Open in Explorer" entry exists on Windows only, for
// device-local rows that carry a real on-disk identity. Remote protocols and
// SAF documents have none, so they must never resolve to an Explorer target.
void main() {
  group('isExplorerRevealVisible', () {
    test('windows + device-local drive path → true', () {
      expect(
        isExplorerRevealVisible(
          onWindows: true,
          storageType: StorageType.internal,
          segments: const ['E:', 'yb', 'a.mp4'],
          persistedUri: 'E:\\yb\\a.mp4',
        ),
        isTrue,
      );
    });

    test('windows + smb network shortcut (UNC) → true', () {
      expect(
        isExplorerRevealVisible(
          onWindows: true,
          storageType: StorageType.network,
          segments: const [r'\\server\share', 'a.mkv'],
          persistedUri: null,
        ),
        isTrue,
      );
    });

    test('windows + smb row stored as split segments → true', () {
      // The authoritative DB segments for a UNC shortcut are `server`,`share`
      // (not a single `\\server\share` marker); the entry must still appear.
      expect(
        isExplorerRevealVisible(
          onWindows: true,
          storageType: StorageType.network,
          segments: const ['server', 'share', 'a.mkv'],
          persistedUri: null,
        ),
        isTrue,
      );
    });

    test('remote protocols / placeholder storage → false', () {
      for (final type in [
        StorageType.webdav,
        StorageType.ftp,
        StorageType.none,
      ]) {
        expect(
          isExplorerRevealVisible(
            onWindows: true,
            storageType: type,
            segments: const ['E:', 'a.mp4'],
            persistedUri: 'E:\\a.mp4',
          ),
          isFalse,
          reason: '$type has no Explorer representation',
        );
      }
    });

    test('non-windows host → false', () {
      expect(
        isExplorerRevealVisible(
          onWindows: false,
          storageType: StorageType.internal,
          segments: const ['E:', 'a.mp4'],
          persistedUri: null,
        ),
        isFalse,
      );
    });

    test('SAF content:// rows are excluded', () {
      expect(
        isExplorerRevealVisible(
          onWindows: true,
          storageType: StorageType.internal,
          segments: const ['content://com.android/tree/primary%3A', 'a.mp4'],
          persistedUri: 'content://com.android/tree/primary%3A/a.mp4',
        ),
        isFalse,
      );
    });

    test('storage-relative segment lists are excluded', () {
      expect(
        isExplorerRevealVisible(
          onWindows: true,
          storageType: StorageType.internal,
          segments: const ['sub', 'dir', 'a.mp4'],
          persistedUri: null,
        ),
        isFalse,
      );
      expect(
        isExplorerRevealVisible(
          onWindows: true,
          storageType: StorageType.internal,
          segments: const [],
          persistedUri: null,
        ),
        isFalse,
      );
    });

    test('a directory row is visible too', () {
      expect(
        isExplorerRevealVisible(
          onWindows: true,
          storageType: StorageType.internal,
          segments: const ['E:', 'yb'],
          persistedUri: null,
        ),
        isTrue,
      );
    });
  });

  group('explorerRevealPath', () {
    test('drive-letter segments are joined as a Windows path', () {
      expect(
        explorerRevealPath(segments: const ['E:', 'yb', 'a.mp4']),
        'E:/yb/a.mp4',
      );
      expect(
        explorerRevealPath(segments: const ['c:', 'Users', 'me', 'a.mkv']),
        'c:/Users/me/a.mkv',
      );
    });

    test('UNC segments become a forward-slash UNC path', () {
      expect(
        explorerRevealPath(segments: const [r'\\server\share', 'a.mp4']),
        '//server/share/a.mp4',
      );
    });

    test('split UNC segments rebuild the UNC form for a network row', () {
      // The path codec stores a UNC shortcut base as `server`,`share` (its
      // canonicalDbPath drops the leading `\\`), so `playableUri` alone yields
      // `/server/share/...`; the network storage type restores `//`.
      expect(
        explorerRevealPath(
          segments: const ['server', 'share', 'a.mp4'],
          storageType: StorageType.network,
        ),
        '//server/share/a.mp4',
      );
    });

    test('a network row with a drive-letter base still resolves by letter', () {
      expect(
        explorerRevealPath(
          segments: const ['Z:', 'a.mp4'],
          storageType: StorageType.network,
        ),
        'Z:/a.mp4',
      );
    });

    test('split segments stay null without the network storage type', () {
      expect(
        explorerRevealPath(
          segments: const ['server', 'share', 'a.mp4'],
          storageType: StorageType.internal,
        ),
        isNull,
      );
    });

    test('SAF / remote / relative segment lists resolve to null', () {
      expect(
        explorerRevealPath(
          segments: const ['content://com.android/tree/primary%3A', 'a.mp4'],
        ),
        isNull,
      );
      expect(
        explorerRevealPath(segments: const ['Movies', 'a.mp4']),
        isNull,
      );
      expect(explorerRevealPath(segments: const []), isNull);
    });

    test('persisted local uri is used when segments cannot resolve', () {
      expect(
        explorerRevealPath(
          segments: const [],
          persistedUri: 'file:///E:/yb/a.mp4',
        ),
        'E:/yb/a.mp4',
      );
      expect(
        explorerRevealPath(
          segments: const [],
          persistedUri: 'E:\\yb\\a.mp4',
        ),
        'E:/yb/a.mp4',
      );
      // Legacy pre-fix shape '/E:/...' is repaired, not rejected.
      expect(
        explorerRevealPath(segments: const [], persistedUri: '/E:/yb/a.mp4'),
        'E:/yb/a.mp4',
      );
    });

    test('http(s) / ftp / content persisted uris never resolve', () {
      for (final uri in [
        'http://host/a.mp4',
        'https://host/a.mp4',
        'ftp?host=h&port=21&path=/a.mp4',
        'content://com.android/tree/x/a.mp4',
      ]) {
        expect(
          explorerRevealPath(segments: const [], persistedUri: uri),
          isNull,
          reason: '$uri is not an on-disk path',
        );
      }
    });
  });

  group('explorerRevealRequest', () {
    test('existing file selects it with a raw /select parameter', () {
      final request = explorerRevealRequest(
        'E:/yb/a.mp4',
        targetExists: true,
        isDir: false,
      );
      expect(request.selectsFile, isTrue);
      expect(request.parameters, '/select,"E:\\yb\\a.mp4"');
      expect(request.folderPath, 'E:\\yb');
    });

    test('missing file opens its parent folder', () {
      final request = explorerRevealRequest(
        'E:/yb/a.mp4',
        targetExists: false,
        isDir: false,
      );
      expect(request.selectsFile, isFalse);
      expect(request.parameters, isNull);
      expect(request.folderPath, 'E:\\yb');
    });

    test('missing file at a drive root opens the drive', () {
      final request = explorerRevealRequest(
        'E:/a.mp4',
        targetExists: false,
        isDir: false,
      );
      expect(request.folderPath, 'E:\\');
    });

    test('existing directory opens itself', () {
      final request = explorerRevealRequest(
        'E:/yb',
        targetExists: true,
        isDir: true,
      );
      expect(request.selectsFile, isFalse);
      expect(request.folderPath, 'E:\\yb');
    });

    test('UNC file keeps the double-backslash form', () {
      final request = explorerRevealRequest(
        '//server/share/a.mp4',
        targetExists: true,
        isDir: false,
      );
      expect(request.parameters, '/select,"\\\\server\\share\\a.mp4"');
    });
  });

  group('revealInExplorer', () {
    test('remote storage is not applicable and never launches', () async {
      var launched = false;
      final outcome = await revealInExplorer(
        storageType: StorageType.webdav,
        segments: const ['Movies', 'a.mp4'],
        onWindows: true,
        launcher: (_) async => launched = true,
      );
      expect(outcome, ExplorerRevealOutcome.notApplicable);
      expect(launched, isFalse);
    });

    test('existing local file launches a select request', () async {
      final requests = <ExplorerRevealRequest>[];
      final outcome = await revealInExplorer(
        storageType: StorageType.internal,
        segments: const ['E:', 'yb', 'a.mp4'],
        onWindows: true,
        exists: (path) => path == 'E:/yb/a.mp4',
        launcher: (request) async => requests.add(request),
      );
      expect(outcome, ExplorerRevealOutcome.launched);
      expect(requests, hasLength(1));
      expect(requests.single.parameters, '/select,"E:\\yb\\a.mp4"');
    });

    test('split UNC network row launches a select request', () async {
      final requests = <ExplorerRevealRequest>[];
      final outcome = await revealInExplorer(
        storageType: StorageType.network,
        segments: const ['server', 'share', 'a.mp4'],
        onWindows: true,
        exists: (path) => path == '//server/share/a.mp4',
        launcher: (request) async => requests.add(request),
      );
      expect(outcome, ExplorerRevealOutcome.launched);
      expect(requests.single.selectsFile, isTrue);
      expect(requests.single.parameters, '/select,"\\\\server\\share\\a.mp4"');
    });

    test('missing file degrades to the parent folder', () async {
      final requests = <ExplorerRevealRequest>[];
      final outcome = await revealInExplorer(
        storageType: StorageType.internal,
        segments: const ['E:', 'yb', 'a.mp4'],
        onWindows: true,
        // File gone, parent still there.
        exists: (path) => path == 'E:/yb',
        launcher: (request) async => requests.add(request),
      );
      expect(outcome, ExplorerRevealOutcome.launched);
      expect(requests.single.selectsFile, isFalse);
      expect(requests.single.folderPath, 'E:\\yb');
    });

    test('missing parent reports folderMissing without launching', () async {
      var launched = false;
      final outcome = await revealInExplorer(
        storageType: StorageType.internal,
        segments: const ['E:', 'yb', 'a.mp4'],
        onWindows: true,
        exists: (_) => false,
        launcher: (_) async => launched = true,
      );
      expect(outcome, ExplorerRevealOutcome.folderMissing);
      expect(launched, isFalse);
    });

    test('a throwing launcher reports launchFailed', () async {
      final outcome = await revealInExplorer(
        storageType: StorageType.internal,
        segments: const ['E:', 'yb', 'a.mp4'],
        onWindows: true,
        exists: (path) => path == 'E:/yb/a.mp4',
        launcher: (_) async => throw StateError('explorer unavailable'),
      );
      expect(outcome, ExplorerRevealOutcome.launchFailed);
    });
  });
}
