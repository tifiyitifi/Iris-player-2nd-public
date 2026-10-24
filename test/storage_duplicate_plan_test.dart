import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/services/storage_duplicate_repair.dart';
import 'package:iris/models/storages/storage.dart';

/// Duplicate-entry detection + survivor choice.
///
/// Only an EXACT duplicate (same stable volume id AND identical base path) may
/// merge: node paths are stored storage-relative, so folding two different
/// bases would re-interpret every stored path.
LocalStorage _local({
  required String id,
  String? volumeId = 'vol:1',
  List<String> basePath = const <String>['E:'],
  StorageType type = StorageType.internal,
  String name = 'Extreme SSD (E:)',
}) =>
    LocalStorage(
      id: id,
      type: type,
      name: name,
      basePath: basePath,
      volumeId: volumeId,
    );

void main() {
  test('the same volume + base is one duplicate group', () {
    final groups = planDuplicateStorageGroups([
      _local(id: 'a'),
      _local(id: 'b'),
    ]);
    expect(groups, hasLength(1));
    expect(groups.single.losers, hasLength(1));
  });

  test('same volume, different base is NOT a duplicate', () {
    final groups = planDuplicateStorageGroups([
      _local(id: 'a'),
      _local(id: 'b', basePath: const <String>['E:', 'yb']),
    ]);
    expect(groups, isEmpty);
  });

  test('different volumes are never grouped', () {
    final groups = planDuplicateStorageGroups([
      _local(id: 'a'),
      _local(id: 'b', volumeId: 'vol:2'),
    ]);
    expect(groups, isEmpty);
  });

  test('an entry without a volume id is never grouped', () {
    final groups = planDuplicateStorageGroups([
      _local(id: 'a'),
      _local(id: 'b', volumeId: null),
    ]);
    expect(groups, isEmpty);
  });

  test('the library owner survives', () {
    final groups = planDuplicateStorageGroups(
      [_local(id: 'new'), _local(id: 'old')],
      libraryStorageIds: {'old'},
      nodeCounts: const {'new': 1000, 'old': 10},
    );
    expect(groups.single.survivor.id, 'old');
  });

  test('then the entry with more rows survives', () {
    final groups = planDuplicateStorageGroups(
      [_local(id: 'new'), _local(id: 'old')],
      nodeCounts: const {'new': 570, 'old': 5555},
    );
    expect(groups.single.survivor.id, 'old');
  });

  test('then the entry with more references survives', () {
    final groups = planDuplicateStorageGroups(
      [_local(id: 'new'), _local(id: 'old')],
      nodeCounts: const {'new': 10, 'old': 10},
      referenceCounts: const {'new': 40, 'old': 2},
    );
    expect(groups.single.survivor.id, 'new');
  });

  test('a full tie keeps the earlier (user-order) entry', () {
    final groups = planDuplicateStorageGroups([
      _local(id: 'first'),
      _local(id: 'second'),
    ]);
    expect(groups.single.survivor.id, 'first');
  });

  test('case-insensitive bases still group on NTFS', () {
    final groups = planDuplicateStorageGroups([
      _local(id: 'a', basePath: const <String>['E:']),
      _local(id: 'b', basePath: const <String>['e:']),
    ]);
    expect(groups, hasLength(1));
  });

  test('three entries fold into one group with two losers', () {
    final groups = planDuplicateStorageGroups([
      _local(id: 'a'),
      _local(id: 'b'),
      _local(id: 'c'),
    ]);
    expect(groups, hasLength(1));
    expect(groups.single.losers, hasLength(2));
  });
}
