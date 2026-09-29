import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/enums/storage_list_error.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/models/storages/storage.dart';

/// Regression guard for "the phone shows an empty folder instead of asking for
/// the storage permission": a refused local listing must be CLASSIFIED as a
/// denial, and an empty listing on Android without the permission must be too.
void main() {
  group('classifyLocalListError', () {
    test('EACCES (13) is a permission denial', () {
      final error = FileSystemException(
        'Directory listing failed',
        '/storage/emulated/0',
        const OSError('Permission denied', 13),
      );
      expect(
        classifyLocalListError(error),
        StorageListErrorKind.permissionDenied,
      );
    });

    test('EPERM (1) is a permission denial', () {
      final error = FileSystemException(
        'Directory listing failed',
        '/storage/emulated/0',
        const OSError('Operation not permitted', 1),
      );
      expect(
        classifyLocalListError(error),
        StorageListErrorKind.permissionDenied,
      );
    });

    test('an unrelated errno stays unknown', () {
      final error = FileSystemException(
        'Directory listing failed',
        '/tmp/x',
        const OSError('No such file or directory', 2),
      );
      expect(classifyLocalListError(error), StorageListErrorKind.unknown);
    });

    test('a non-filesystem error stays unknown', () {
      expect(classifyLocalListError(StateError('boom')),
          StorageListErrorKind.unknown);
    });
  });

  group('emptyLocalListingKind', () {
    test('Android without the permission treats an empty listing as denied', () {
      expect(
        emptyLocalListingKind(
          isAndroid: true,
          permissionGranted: false,
          itemCount: 0,
        ),
        StorageListErrorKind.permissionDenied,
      );
    });

    test('Android with the permission keeps a genuinely empty folder empty',
        () {
      expect(
        emptyLocalListingKind(
          isAndroid: true,
          permissionGranted: true,
          itemCount: 0,
        ),
        isNull,
      );
    });

    test('a non-empty listing is never rewritten', () {
      expect(
        emptyLocalListingKind(
          isAndroid: true,
          permissionGranted: false,
          itemCount: 3,
        ),
        isNull,
      );
    });

    test('desktop is never rewritten (its status is always granted)', () {
      expect(
        emptyLocalListingKind(
          isAndroid: false,
          permissionGranted: false,
          itemCount: 0,
        ),
        isNull,
      );
    });
  });

  group('getLocalFilesResult', () {
    test('a missing directory stays a non-error empty result on this host', () async {
      final storage = LocalStorage(
        id: 'missing',
        type: StorageType.internal,
        name: 'Missing',
        basePath: const ['/definitely/not/here'],
      );

      final result =
          await getLocalFilesResult(storage, const ['/definitely/not/here']);

      expect(result.hasError, isFalse);
      expect(result.items, isEmpty);
    });

    test('a traversal path is rejected without being reported as an error',
        () async {
      final storage = LocalStorage(
        id: 't',
        type: StorageType.internal,
        name: 'T',
        basePath: const ['/tmp'],
      );

      final result = await getLocalFilesResult(storage, const ['..', 'etc']);

      expect(result.hasError, isFalse);
      expect(result.items, isEmpty);
    });
  });
}
