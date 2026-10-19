import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/migration/v50_migration.dart';
import 'package:iris/models/file.dart';

/// Schema v50 contract: `media_nodes.subtitles_json` persists the external
/// subtitle associations computed from a storage listing.
///
/// The bug it fixes: subtitles were only ever attached by the live listing, so
/// playing the same file from a DB-resolved surface (scenario / tag / play
/// queue / library tab) offered no external track at all.
///
/// Semantics pinned here:
///  * NULL  = association UNKNOWN (pre-v50 row, or a lane that cannot see it);
///  * `[]`  = KNOWN to have none;
///  * an upsert that does not know them (absent) must NOT clear stored ones.
void main() {
  late AppDatabase db;
  late MediaNodesDao dao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = MediaNodesDao(db);
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() async {
    await db.close();
  });

  Future<Set<String>> mediaNodeColumns() async {
    final rows = await db.customSelect('PRAGMA table_info(media_nodes)').get();
    return {for (final row in rows) row.read<String>('name')};
  }

  const subs = <Subtitle>[
    Subtitle(
      name: 'Show.S01E01.zh-ru.ass',
      uri: 'http://h/Show.S01E01.zh-ru.ass',
    ),
    Subtitle(
      name: 'Show.S01E01.zh-ru.srt',
      uri: 'http://h/Show.S01E01.zh-ru.srt',
    ),
  ];

  MediaNode fileNode({List<Subtitle>? subtitles}) => MediaNode.file(
        id: 'st1:Show.S01E01.mp4',
        storageId: 'st1',
        path: const ['Show.S01E01.mp4'],
        name: 'Show.S01E01.mp4',
        mediaType: MediaType.video,
        subtitles: subtitles,
      );

  Future<List<Subtitle>?> readBackSubtitles() async {
    final row = await dao.getByPath('st1', 'Show.S01E01.mp4');
    final node = MediaNodeDriftAdapter.fromDb(row!);
    return node.maybeMap(file: (f) => f.subtitles, orElse: () => null);
  }

  test('schemaVersion advanced to 50', () {
    expect(db.schemaVersion, greaterThanOrEqualTo(50));
  });

  test('media_nodes carries the subtitles_json column', () async {
    expect(await mediaNodeColumns(), contains('subtitles_json'));
  });

  test('MigrationV50 is re-entrant (no-op when the column exists)',
      () async {
    await MigrationV50(db).run(db.createMigrator());
    expect(await mediaNodeColumns(), contains('subtitles_json'));
  });

  test('adapter round-trips the subtitle list in order', () async {
    await dao.batchUpsert([fileNode(subtitles: subs).toCompanion()]);
    expect(await readBackSubtitles(), subs);
  });

  test('a known-empty list is stored as [] and reads back EMPTY (not null)',
      () async {
    await dao.batchUpsert([fileNode(subtitles: const []).toCompanion()]);
    final raw = await db.customSelect(
      'SELECT subtitles_json AS j FROM media_nodes WHERE storage_id = ?',
      variables: [Variable.withString('st1')],
    ).getSingle();
    expect(raw.read<String?>('j'), '[]');
    expect(await readBackSubtitles(), isEmpty);
  });

  test('a never-captured row reads back as null (unknown)', () async {
    await dao.batchUpsert([fileNode().toCompanion()]);
    expect(await readBackSubtitles(), isNull);
  });

  test('an unknown (absent) upsert does not wipe stored associations',
      () async {
    await dao.batchUpsert([fileNode(subtitles: subs).toCompanion()]);
    await dao.batchUpsert([fileNode().toCompanion()]);
    expect(await readBackSubtitles(), subs);
  });

  test('malformed json degrades to an empty list, never a crash', () async {
    await dao.batchUpsert([fileNode(subtitles: subs).toCompanion()]);
    await db.customStatement(
      'UPDATE media_nodes SET subtitles_json = ? WHERE storage_id = ?',
      ['{not json', 'st1'],
    );
    expect(await readBackSubtitles(), isEmpty);
  });

  group('MediaNodeDriftAdapter.sameSubtitles (the incremental-scan predicate)',
      () {
    const a = Subtitle(name: 'v.zh.ass', uri: 'ftp?path=/a/v.zh.ass');
    const b = Subtitle(name: 'v.en.srt', uri: 'ftp?path=/a/v.en.srt');
    const encodedA = '[{"name":"v.zh.ass","uri":"ftp?path=/a/v.zh.ass"}]';

    test('a never-captured payload is NOT "same" (it is re-upserted once)', () {
      expect(MediaNodeDriftAdapter.sameSubtitles(null, const []), isFalse);
      expect(MediaNodeDriftAdapter.sameSubtitles(null, const [a]), isFalse);
    });

    test('a lane that cannot see subtitles never triggers a rewrite', () {
      expect(MediaNodeDriftAdapter.sameSubtitles('[]', null), isTrue);
      expect(MediaNodeDriftAdapter.sameSubtitles(encodedA, null), isTrue);
    });

    test('the known-empty fast path compares as a plain string', () {
      expect(MediaNodeDriftAdapter.sameSubtitles('[]', const []), isTrue);
      expect(MediaNodeDriftAdapter.sameSubtitles('[]', const [a]), isFalse);
      expect(MediaNodeDriftAdapter.sameSubtitles(encodedA, const []), isFalse);
    });

    test('order does not matter but the set does', () {
      final ab = '[{"name":"v.zh.ass","uri":"ftp?path=/a/v.zh.ass"},'
          '{"name":"v.en.srt","uri":"ftp?path=/a/v.en.srt"}]';
      expect(MediaNodeDriftAdapter.sameSubtitles(ab, const [b, a]), isTrue);
      expect(MediaNodeDriftAdapter.sameSubtitles(ab, const [a]), isFalse);
    });

    test('a malformed payload is treated as changed so it is rewritten', () {
      expect(MediaNodeDriftAdapter.sameSubtitles('{not json', const [a]),
          isFalse);
    });
  });
}
