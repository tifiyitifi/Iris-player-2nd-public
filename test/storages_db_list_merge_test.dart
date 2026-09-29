import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/widgets/popups/storages/db/storages_utils/storage_utils.dart';

/// Regression guard for "the storagedb's Storage tab is completely blank".
///
/// `generateStorageId` keys a local disk on its stable volume id and
/// `makeLocalStorage` assigns it, so the freshly enumerated entry and its
/// persisted twin share BOTH `id` and `volumeId`. The previous inline merge hid
/// the scanned entry by volume id AND the persisted one by id — every matched
/// disk cancelled itself out and the list rendered nothing.
void main() {
  LocalStorage disk(String volumeId, {String name = 'Internal'}) =>
      makeLocalStorage(
        type: StorageType.internal,
        name: name,
        basePath: const ['/storage/emulated/0'],
        volumeId: volumeId,
      );

  test('an enumeration and its persisted twin are the same entry', () {
    // Documents WHY matching one side only cancels the pair out.
    expect(disk('vol:emulated').id, disk('vol:emulated').id);
  });

  test('a disk present in both the scan and the store renders exactly once',
      () {
    final scanned = disk('vol:emulated');
    final stored = disk('vol:emulated', name: 'My phone');

    final merged = mergeScannedAndStoredStorages(
      scanned: [scanned],
      stored: [stored],
    );

    expect(merged, hasLength(1));
    // The persisted entry wins: it carries the user's rename and saved scope.
    expect(merged.single.id, stored.id);
    expect(merged.single.name, 'My phone');
  });

  test('a newly mounted disk is added next to the persisted entries', () {
    final persisted = disk('vol:emulated');
    final fresh = makeLocalStorage(
      type: StorageType.internal,
      name: 'USB',
      basePath: const ['/storage/9C33-6BBD'],
      volumeId: 'vol:9c33-6bbd',
    );
    final webdav = WebDAVStorage(
      id: 'w',
      name: 'NAS',
      host: '192.168.1.2',
      port: '5005',
      username: '',
      password: '',
      https: false,
      basePath: const [],
    );

    final merged = mergeScannedAndStoredStorages(
      scanned: [persisted, fresh],
      stored: [persisted, webdav],
    );

    expect(merged.map((s) => s.id), [fresh.id, persisted.id, 'w']);
  });

  test('an entry matched only by volume id (different names) still renders once',
      () {
    final scanned = disk('vol:emulated', name: 'Internal');
    // A renamed persisted entry keeps its id (the id is volume-keyed, not
    // name-keyed) — this is the same case as above, asserted explicitly.
    final stored = disk('vol:emulated', name: 'Phone storage');

    expect(
      mergeScannedAndStoredStorages(scanned: [scanned], stored: [stored]),
      hasLength(1),
    );
  });

  test('a local entry without a volume id is matched by id', () {
    final scanned = makeLocalStorage(
      type: StorageType.internal,
      name: 'X',
      basePath: const ['/mnt/x'],
    );
    expect(scanned.volumeId, isNull);

    final merged = mergeScannedAndStoredStorages(
      scanned: [scanned],
      stored: [scanned],
    );

    expect(merged, hasLength(1));
  });

  test('a scan-only disk with no persisted twin is shown', () {
    final scanned = disk('vol:emulated', name: 'Internal');

    expect(
      mergeScannedAndStoredStorages(scanned: [scanned], stored: const []),
      hasLength(1),
    );
  });

  test('an empty scan still renders the persisted entries', () {
    final stored = disk('vol:emulated');

    final merged =
        mergeScannedAndStoredStorages(scanned: const [], stored: [stored]);

    expect(merged.single.id, stored.id);
  });
}
