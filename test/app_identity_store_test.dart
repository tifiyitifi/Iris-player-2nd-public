import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_identity/model/domain/app_identity_entry.dart';
import 'package:iris/features/app_identity/services/identity_persistence.dart';
import 'package:iris/features/app_identity/store/use_app_identity_store.dart';

/// In-memory persistence backend capturing every write for assertions.
class _MemPersistence implements IdentityPersistence {
  final Map<String, String> rows = {};

  @override
  Future<Map<String, String>> loadAll() async => Map.of(rows);

  @override
  Future<void> saveRow(String key, String encoded) async {
    rows[key] = encoded;
  }
}

AppIdentityEntry _entry(String id, {String name = 'Entry'}) =>
    AppIdentityEntry(
      id: id,
      name: name,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

void main() {
  group('AppIdentityStore CRUD', () {
    test('fresh store loads empty state', () async {
      final store = AppIdentityStore(persistence: _MemPersistence());
      await store.load();
      expect(store.state.entries, isEmpty);
      expect(store.state.activeEntryId, isNull);
    });

    test('upsertEntry adds then updates and persists JSON row', () async {
      final mem = _MemPersistence();
      final store = AppIdentityStore(persistence: mem);
      await store.load();

      await store.upsertEntry(_entry('a', name: 'Alpha'));
      expect(store.state.entries.single.name, 'Alpha');
      expect(mem.rows.containsKey('identity.entry.a'), isTrue);

      // Update the same id — no duplicate.
      await store.upsertEntry(_entry('a', name: 'Renamed'));
      expect(store.state.entries.single.name, 'Renamed');
      expect(mem.rows.length, 1);

      // Reload from persistence reproduces state (round-trip).
      final reloaded = AppIdentityStore(persistence: mem);
      await reloaded.load();
      expect(reloaded.state.entries.single.name, 'Renamed');
    });

    test('upsertEntry trims the name', () async {
      final store = AppIdentityStore(persistence: _MemPersistence());
      await store.upsertEntry(_entry('a', name: '  Padded  '));
      expect(store.state.entries.single.name, 'Padded');
    });

    test('upsertEntry persists sourcePath + crop rect fields', () async {
      final mem = _MemPersistence();
      final store = AppIdentityStore(persistence: mem);
      await store.load();

      await store.upsertEntry(AppIdentityEntry(
        id: 'img',
        name: 'Image entry',
        imageRef: 'identity/entry_img_v2.png',
        imageVersion: 2,
        sourcePath: 'identity/source_img.jpg',
        cropLeft: 0.1,
        cropTop: 0.2,
        cropRight: 0.6,
        cropBottom: 0.7,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      // Round-trip through the persisted JSON row.
      final reloaded = AppIdentityStore(persistence: mem);
      await reloaded.load();
      final e = reloaded.state.entries.single;
      expect(e.imageRef, 'identity/entry_img_v2.png');
      expect(e.imageVersion, 2);
      expect(e.sourcePath, 'identity/source_img.jpg');
      expect(e.cropLeft, 0.1);
      expect(e.cropTop, 0.2);
      expect(e.cropRight, 0.6);
      expect(e.cropBottom, 0.7);
    });

    test('upsertEntry rejects invalid names', () async {
      final store = AppIdentityStore(persistence: _MemPersistence());
      expect(
        () => store.upsertEntry(_entry('a', name: '')),
        throwsArgumentError,
      );
      expect(
        () => store.upsertEntry(_entry('a', name: 'bad\nname')),
        throwsArgumentError,
      );
    });

    test('multiple entries sort by createdAt', () async {
      final store = AppIdentityStore(persistence: _MemPersistence());
      await store.upsertEntry(AppIdentityEntry(
        id: 'new',
        name: 'New',
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ));
      await store.upsertEntry(AppIdentityEntry(
        id: 'old',
        name: 'Old',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));
      expect(store.state.entries.map((e) => e.id).toList(), ['old', 'new']);
    });

    test('deleteEntry removes row and clears active flag when active',
        () async {
      final mem = _MemPersistence();
      final store = AppIdentityStore(persistence: mem);
      await store.upsertEntry(_entry('a'));
      await store.setActiveEntry('a');
      expect(mem.rows['identity.activeEntry'], 'a');

      await store.deleteEntry('a');
      expect(store.state.entries, isEmpty);
      expect(store.state.activeEntryId, isNull);
      // Project-wide AUX contract: deletion writes an EMPTY row (the
      // TagPlayStore precedent), it never removes the key.
      expect(mem.rows['identity.entry.a'], '');
      expect(mem.rows['identity.activeEntry'], '');
    });
  });

  group('AppIdentityStore active entry', () {
    test('setActiveEntry round-trips through persistence', () async {
      final mem = _MemPersistence();
      final store = AppIdentityStore(persistence: mem);
      await store.setActiveEntry('x');
      expect(mem.rows['identity.activeEntry'], 'x');

      final reloaded = AppIdentityStore(persistence: mem);
      await reloaded.load();
      expect(reloaded.state.activeEntryId, 'x');

      await store.setActiveEntry(null);
      expect(mem.rows['identity.activeEntry'], '');
    });
  });

  group('AppIdentityStore capability', () {
    test('setSupported updates state only (not persisted)', () async {
      final mem = _MemPersistence();
      final store = AppIdentityStore(persistence: mem);
      await store.setSupported(true);
      expect(store.state.supported, isTrue);
      expect(mem.rows, isEmpty);
    });
  });

  group('AppIdentityStore entry state mode', () {
    test('new entries default to independent (sharedWithDefault false)',
        () async {
      final store = AppIdentityStore(persistence: _MemPersistence());
      await store.upsertEntry(_entry('a'));
      final e = store.state.entries.single;
      expect(e.sharedWithDefault, isFalse);
      expect(e.initializedAt, isNull);
      expect(e.workspaceScenarioId, isNull);
    });

    test('legacy scenarioId/tagId migrate to one-time seed fields', () async {
      final mem = _MemPersistence()
        ..rows['identity.entry.old'] = jsonEncode({
          'id': 'old',
          'name': 'Legacy',
          'scenarioId': 'sc-1',
          'tagId': 7,
          'lastItemId': 'ignored',
        });
      final store = AppIdentityStore(persistence: mem);
      await store.load();
      final e = store.state.entries.single;
      expect(e.seedScenarioId, 'sc-1');
      expect(e.seedTagId, 7);
      expect(e.sharedWithDefault, isFalse);
      expect(e.initializedAt, isNull);
    });
  });

  group('load outcome', () {
    test('a successful load flips `loaded`, even with no entries', () async {
      final store = AppIdentityStore(persistence: _MemPersistence());
      expect(store.loaded, isFalse);
      await store.load();
      expect(store.loaded, isTrue,
          reason: 'an empty entry list is a VALID loaded state — deletion '
              'cleanup must still be allowed to run');
    });

    test('a failed load stays unloaded so maintenance cannot sweep', () async {
      final store = AppIdentityStore(persistence: _ThrowingPersistence());
      await store.load();
      expect(store.loaded, isFalse,
          reason: 'an empty list after a failure must not be confused with '
              '"no entry references any workspace"');
      expect(store.state.entries, isEmpty);
    });
  });
}

/// Persistence backend whose every read fails (a broken AUX read at startup).
class _ThrowingPersistence implements IdentityPersistence {
  @override
  Future<Map<String, String>> loadAll() async =>
      throw StateError('aux read failed');

  @override
  Future<void> saveRow(String key, String encoded) async {}
}
