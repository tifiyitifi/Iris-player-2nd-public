import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/migration/v51_migration.dart';
import 'package:iris/utils/path_conv.dart';

/// Schema v51 contract: a SAF single-picked file is identified by its document
/// uri, stored as the `media_nodes.path` value.
///
/// A single pick (`ACTION_OPEN_DOCUMENT`) is not under a tree, so it has NO
/// segment path. Older rows stored `path = ''` and put the identity in `uri`,
/// which `UNIQUE(data_scope_id, path)` collapsed onto ONE row per storage: a
/// second pick overwrote the first, and a duration write-back (a path-keyed
/// write) could only address whichever pick owned the empty path.
void main() {
  late AppDatabase db;
  late MediaNodesDao dao;

  // A `document/`-shaped uri (NOT tree-shaped) so the canonicalization is
  // actually exercised: the intact `content://` scheme must be PRESERVED (it was
  // once collapsed to `content:/`, which MigrationV23 repaired).
  const safDocUri =
      'content://com.android.providers.media.documents/document/video%3A101';
  const safTreeUri = 'content://com.android.externalstorage.documents/tree/'
      'primary%3ADownload/document/primary%3ADownload%2Fsaf.mp4';

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = MediaNodesDao(db);
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() async {
    await db.close();
  });

  MediaNode safFile(String uri, String name) => MediaNode.file(
        id: 'st1:$uri',
        storageId: 'st1',
        path: const <String>[],
        name: name,
        mediaType: MediaType.video,
        uri: uri,
      );

  test('schemaVersion advanced to 51', () {
    expect(db.schemaVersion, greaterThanOrEqualTo(51));
  });

  group('canonicalFilePath', () {
    test('a path-less SAF file is keyed by its document uri', () {
      expect(
        MediaNodeDriftAdapter.canonicalFilePath(
          storageId: 'st1',
          path: const <String>[],
          uri: safDocUri,
        ),
        canonicalDbPath(safDocUri),
      );
    });

    test('a tree-shaped SAF uri round-trips unchanged', () {
      expect(
        MediaNodeDriftAdapter.canonicalFilePath(
          storageId: 'st1',
          path: const <String>[],
          uri: safTreeUri,
        ),
        safTreeUri,
      );
    });

    test('a real segment path wins; the uri is only the empty-path fallback',
        () {
      expect(
        MediaNodeDriftAdapter.canonicalFilePath(
          storageId: 'st1',
          path: const <String>['Anime', 'a.mp4'],
          uri: safDocUri,
        ),
        'Anime/a.mp4',
      );
      expect(
        MediaNodeDriftAdapter.canonicalFilePath(
          storageId: 'st1',
          path: const <String>[],
          uri: null,
        ),
        '',
      );
    });
  });

  group('two single picks of one storage coexist', () {
    test('the second upsert does not overwrite the first', () async {
      await dao.upsertNode(safFile(safDocUri, 'one.mp4'));
      await dao.upsertNode(safFile(safTreeUri, 'two.mp4'));

      final one = await dao.getByPath('st1', safDocUri);
      final two = await dao.getByPath('st1', safTreeUri);
      expect(one, isNotNull, reason: 'the first pick must survive');
      expect(two, isNotNull);
      expect(one!.id, isNot(two!.id));
      expect(one.name, 'one.mp4');
      expect(two.name, 'two.mp4');

      // The identity every consumer derives must agree with the stored path.
      final node = MediaNodeDriftAdapter.fromDb(one);
      expect(node.occurrencePath, canonicalDbPath(safDocUri));
    });

    test('a re-upsert of the same pick updates in place, not duplicates',
        () async {
      await dao.upsertNode(safFile(safDocUri, 'one.mp4'));
      await dao.upsertNode(safFile(safDocUri, 'one.mp4'));
      final all = await dao.getByPath('st1', safDocUri);
      expect(all, isNotNull);
      final count = await db.customSelect(
        "SELECT COUNT(*) AS c FROM media_nodes WHERE path = ?",
        variables: [Variable.withString(canonicalDbPath(safDocUri))],
      ).getSingle();
      expect(count.read<int>('c'), 1);
    });

    test('a legacy collapsed-scheme row is still found by the intact uri',
        () async {
      // Rows written before the scheme was preserved live under `content:/…`.
      await db.customStatement(
        'INSERT INTO media_nodes '
        '(storage_id, data_scope_id, path, name, node_kind, uri) '
        "VALUES ('st1', 'st1', ?, 'legacy.mp4', 'file', ?)",
        [collapsedSafSchemePath(safDocUri), safDocUri],
      );
      final row = await dao.getByPathCanonical('st1', safDocUri);
      expect(row, isNotNull,
          reason: 'the intact uri must still reach the legacy row');
      expect(row!.name, 'legacy.mp4');
    });
  });

  group('MigrationV51', () {
    /// Inserts a pre-v51 row BYPASSING the adapter (raw `path = ''` + uri).
    Future<void> insertLegacy(String uri, String name,
        {String scope = 'st1'}) async {
      await db.customStatement(
        'INSERT INTO media_nodes '
        '(storage_id, data_scope_id, path, name, node_kind, uri) '
        "VALUES ('st1', ?, '', ?, 'file', ?)",
        [scope, name, uri],
      );
    }

    test('re-keys an empty-path SAF file row onto its uri', () async {
      await insertLegacy(safDocUri, 'one.mp4');
      await MigrationV51(db).run(db.createMigrator());

      final row = await dao.getByPath('st1', safDocUri);
      expect(row, isNotNull);
      expect(row!.path, canonicalDbPath(safDocUri));
    });

    test('drops a legacy duplicate when the row is already re-keyed', () async {
      await insertLegacy(safDocUri, 'legacy.mp4');
      await db.customStatement(
        'INSERT INTO media_nodes '
        '(storage_id, data_scope_id, path, name, node_kind, uri) '
        "VALUES ('st1', 'st1', ?, 'current.mp4', 'file', ?)",
        [canonicalDbPath(safDocUri), safDocUri],
      );
      await MigrationV51(db).run(db.createMigrator());

      final rows = await db.customSelect(
        'SELECT name FROM media_nodes WHERE path = ?',
        variables: [Variable.withString(canonicalDbPath(safDocUri))],
      ).get();
      expect(rows, hasLength(1));
      expect(rows.single.read<String>('name'), 'current.mp4');
    });

    test('merges a deleted duplicate\'s data into the surviving row', () async {
      // The legacy empty-path row is the one the OLD writer keyed progress
      // writes on; the canonical row may exist without any of it. Deleting the
      // legacy row must not throw that progress away.
      await db.customStatement(
        'INSERT INTO media_nodes '
        '(storage_id, data_scope_id, path, name, node_kind, uri, duration_ms, '
        'width, height, size_in_bytes, subtitles_json, playback_position_ms, '
        'playback_completed, last_played_at, play_count, '
        'history_restore_budget) '
        "VALUES ('st1', 'st1', '', 'legacy.mp4', 'file', ?, 5000, 1920, 1080, "
        "12345, ?, 42000, 1, 2000, 4, 2)",
        [
          safDocUri,
          '[{"name":"a.srt","uri":"/sdcard/a.srt"}]',
        ],
      );
      await db.customStatement(
        'INSERT INTO media_nodes '
        '(storage_id, data_scope_id, path, name, node_kind, uri) '
        "VALUES ('st1', 'st1', ?, 'current.mp4', 'file', ?)",
        [canonicalDbPath(safDocUri), safDocUri],
      );

      await MigrationV51(db).run(db.createMigrator());

      final row = await db.customSelect(
        'SELECT * FROM media_nodes WHERE path = ?',
        variables: [Variable.withString(canonicalDbPath(safDocUri))],
      ).getSingle();
      expect(row.read<String>('name'), 'current.mp4',
          reason: 'the canonical row keeps its identity');
      expect(row.read<int?>('duration_ms'), 5000);
      expect(row.read<int?>('width'), 1920);
      expect(row.read<int?>('height'), 1080);
      expect(row.read<int?>('pixel_count'), 1920 * 1080,
          reason: 'the merged dimensions must keep the sort cache in sync');
      expect(row.read<int?>('size_in_bytes'), 12345);
      expect(row.read<String?>('subtitles_json'),
          '[{"name":"a.srt","uri":"/sdcard/a.srt"}]');
      expect(row.read<int?>('playback_position_ms'), 42000);
      expect(row.read<int?>('playback_completed'), 1);
      expect(row.read<int?>('last_played_at'), 2000);
      expect(row.read<int?>('play_count'), 4);
      expect(row.read<int?>('history_restore_budget'), 2);
    });

    test('a newer target progress wins over an older legacy one', () async {
      await db.customStatement(
        'INSERT INTO media_nodes '
        '(storage_id, data_scope_id, path, name, node_kind, uri, duration_ms, '
        'playback_position_ms, last_played_at, play_count) '
        "VALUES ('st1', 'st1', '', 'legacy.mp4', 'file', ?, 5000, 1111, 1000, 2)",
        [safDocUri],
      );
      await db.customStatement(
        'INSERT INTO media_nodes '
        '(storage_id, data_scope_id, path, name, node_kind, uri, '
        'playback_position_ms, last_played_at, play_count) '
        "VALUES ('st1', 'st1', ?, 'current.mp4', 'file', ?, 9999, 3000, 8)",
        [canonicalDbPath(safDocUri), safDocUri],
      );

      await MigrationV51(db).run(db.createMigrator());

      final row = await db.customSelect(
        'SELECT * FROM media_nodes WHERE path = ?',
        variables: [Variable.withString(canonicalDbPath(safDocUri))],
      ).getSingle();
      expect(row.read<int?>('playback_position_ms'), 9999,
          reason: 'the most recently played row owns the resume point');
      expect(row.read<int?>('last_played_at'), 3000);
      expect(row.read<int?>('play_count'), 8,
          reason: 'the lifetime counter keeps the larger value');
      expect(row.read<int?>('duration_ms'), 5000,
          reason: 'a missing content column is filled from the duplicate');
    });

    test('re-entrant: a second run changes nothing', () async {
      await insertLegacy(safTreeUri, 'one.mp4');
      await MigrationV51(db).run(db.createMigrator());
      await MigrationV51(db).run(db.createMigrator());
      final row = await dao.getByPath('st1', safTreeUri);
      expect(row!.path, safTreeUri);
    });

    test('leaves a real segment path alone', () async {
      await dao.upsertNode(MediaNode.file(
        id: 'st1:Anime/a.mp4',
        storageId: 'st1',
        path: const <String>['Anime', 'a.mp4'],
        name: 'a.mp4',
        mediaType: MediaType.video,
      ));
      await MigrationV51(db).run(db.createMigrator());
      expect((await dao.getByPath('st1', 'Anime/a.mp4'))?.path, 'Anime/a.mp4');
    });
  });
}
