import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/services/storage_duplicate_repair.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/storages/storage.dart';

/// Duplicate-entry merge against a real (in-memory) Drift database.
///
/// Covers the field shape: the OLD entry owns the scanned tree and the library,
/// the NEW entry re-scanned the same drive into its own scope (564 identical
/// paths + 6 new ones). Merging must collapse the duplicates without losing
/// playback progress, move the new rows, repoint every reference (including the
/// persisted occurrence JSON) and leave no phantom rows behind.
LocalStorage _entry(
  String id, {
  String name = 'Extreme SSD (E:)',
  List<String> basePath = const <String>['E:'],
}) =>
    LocalStorage(
      id: id,
      type: StorageType.internal,
      name: name,
      basePath: basePath,
      volumeId: 'vol:e9471df0',
    );

void main() {
  late AppDatabase db;
  late MediaNodesDao dao;

  setUpAll(() {
    db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
    StoragePathCodec.baseResolver = (id) => const ['E:'];
  });

  tearDownAll(() async {
    StoragePathCodec.baseResolver = (_) => null;
    await db.close();
  });

  setUp(() async {
    for (final table in <String>[
      'media_nodes',
      'scenario_sources',
      'scenario_explicit_items',
      'scenario_excludes',
      'scenario_state',
      'scenario_queue_builds',
      'scenario_shared_index',
      'video_tag_members',
      'favorites_table',
      'navigation_table',
      'bg_mapping_segments_table',
      'bg_mappings_table',
      'scan_states',
      'scan_queue',
      'media_lib_sources',
      'media_libs',
    ]) {
      await db.customStatement('DELETE FROM $table');
    }
    dao = DbModule.mediaNodesDao;
  });

  Future<void> node(
    String storageId,
    String path, {
    int? positionMs,
    int playCount = 0,
    DateTime? lastPlayedAt,
    bool present = true,
  }) =>
      dao.insertNode(MediaNode.file(
        id: '$storageId:$path',
        storageId: storageId,
        path: path.split('/'),
        parentPath: path.contains('/')
            ? path.substring(0, path.lastIndexOf('/'))
            : null,
        pathDepth: path.split('/').length - 1,
        name: path.split('/').last,
        mediaType: MediaType.video,
        isPresent: present,
        playbackPositionMs: positionMs,
        playCount: playCount,
        lastPlayedAt: lastPlayedAt,
      ));

  Future<int> exec(String sql, [List<Object?> args = const []]) =>
      db.customUpdate(
        sql,
        variables: <Variable<Object>>[
          for (final arg in args) Variable<Object>(arg),
        ],
      );

  Future<MediaNodesTableData> row(String scope, String path) async {
    final rows = await dao.rowsInScope(scope);
    return rows.firstWhere((r) => r.path == path);
  }

  Future<void> seed() async {
    // Survivor (old) — the real scanned tree.
    await node('old', 'yb/a.mp4');
    await node('old', 'yb/b.mp4');
    await dao.insertNode(MediaNode.directory(
      id: 'old:yb/dir',
      storageId: 'old',
      path: const <String>['yb', 'dir'],
      pathDepth: 1,
      name: 'dir',
    ));
    await dao.updatePlaybackProgress(
      storageId: 'old',
      path: 'yb/a.mp4',
      positionMs: 1000,
      playCount: 2,
      lastPlayedAt: DateTime(2026, 1, 1),
    );

    // Loser (new) — a re-scan of the same drive into its own scope.
    await node('new', 'yb/a.mp4');
    await node('new', 'yb/b.mp4');
    await node('new', 'yb/c.mp4');
    await dao.insertNode(MediaNode.directory(
      id: 'new:yb/dir',
      storageId: 'new',
      path: const <String>['yb', 'dir'],
      pathDepth: 1,
      name: 'dir',
    ));
    await dao.updatePlaybackProgress(
      storageId: 'new',
      path: 'yb/a.mp4',
      positionMs: 9000,
      playCount: 5,
      lastPlayedAt: DateTime(2026, 2, 1),
    );
    // A pre-fix phantom: the storage base row in absolute form.
    await exec(
      "INSERT INTO media_nodes (storage_id, data_scope_id, path, name, "
      "node_kind, is_present) VALUES ('new', 'new', 'E:', 'E:', 'directory', 1)",
    );

    // References owned by the loser entry.
    await exec(
      "INSERT INTO scenario_sources (scenario_id, storage_id, path, recursive, "
      "source_kind, sort_order) VALUES ('S', 'new', 'E:/yb', 1, 'folder', 0)",
    );
    await exec(
      "INSERT INTO scenario_explicit_items (scenario_id, storage_id, path, "
      "add_order) VALUES ('S', 'new', 'E:/yb/c.mp4', 1)",
    );
    await exec(
      "INSERT INTO video_tag_members (tag_id, storage_id, path) "
      "VALUES (1, 'old', 'E:/yb/a.mp4')",
    );
    await exec(
      "INSERT INTO video_tag_members (tag_id, storage_id, path) "
      "VALUES (1, 'new', 'E:/yb/a.mp4')",
    );
    await exec(
      "INSERT INTO video_tag_members (tag_id, storage_id, path) "
      "VALUES (2, 'new', 'E:/yb/b.mp4')",
    );
    await exec(
      "INSERT INTO favorites_table (storage_id, path) VALUES ('new', 'E:/yb/x')",
    );
    await exec(
      "INSERT INTO navigation_table (key, current_storage_id, current_path_json) "
      "VALUES ('main', 'new', '[]')",
    );
    await exec(
      "INSERT INTO bg_mappings_table (storage_id, path) VALUES ('new', 'E:/yb/b.mp4')",
    );
    await exec(
      "INSERT INTO bg_mapping_segments_table (mapping_id, action, fg_start_ms, "
      "fg_end_ms, bg_storage_id, bg_path) "
      "VALUES (1, 'playMedia', 0, 1000, 'new', 'E:/yb/b.mp4')",
    );
    await exec(
      "INSERT INTO scan_states (storage_id, data_scope_id, path, status) "
      "VALUES ('new', 'new', 'yb', 1)",
    );
    await exec(
      "INSERT INTO scan_queue (storage_id, data_scope_id, path, depth) "
      "VALUES ('new', 'new', 'yb', 0)",
    );
    await exec(
      "INSERT INTO scenario_state (scenario_id, current_playback_occurrence) "
      '''VALUES ('S', '{"storageId":"new","path":"E:/yb/c.mp4","occurrenceIndex":0}')''',
    );
  }

  Future<StorageMergeStats> merge() => mergeDuplicateStorageGroup(
        StorageDuplicateGroup(
          survivor: _entry('old'),
          losers: <LocalStorage>[_entry('new')],
        ),
        sweepMissingFiles: false,
        notifyRevisions: false,
        removeEntry: (_) async {},
      );

  test('duplicate paths collapse, losing only the redundant rows', () async {
    await seed();
    final stats = await merge();

    final oldRows = await dao.rowsInScope('old');
    expect(await dao.rowsInScope('new'), isEmpty);
    expect(stats.mergedNodes, 3); // yb/a.mp4, yb/b.mp4, yb/dir
    expect(stats.movedNodes, 1); // yb/c.mp4
    expect(stats.droppedPhantoms, 1); // the absolute 'E:' row

    expect(
      oldRows.map((r) => r.path).toSet(),
      {'yb/a.mp4', 'yb/b.mp4', 'yb/c.mp4', 'yb/dir'},
    );
    expect(oldRows.where((r) => r.path == 'yb/c.mp4').single.storageId, 'old');
    expect(oldRows.where((r) => r.path == 'yb/c.mp4').single.dataScopeId, 'old');
  });

  test('the most recently played progress survives', () async {
    await seed();
    await merge();

    final merged = await row('old', 'yb/a.mp4');
    expect(merged.playbackPositionMs, 9000);
    expect(merged.playCount, 5);
    expect(merged.lastPlayedAt, DateTime(2026, 2, 1));
  });

  test('every reference is repointed and collisions are dropped', () async {
    await seed();
    await merge();

    final source = await db
        .customSelect("SELECT storage_id FROM scenario_sources WHERE scenario_id = 'S'")
        .getSingle();
    expect(source.read<String>('storage_id'), 'old');

    final explicit = await db
        .customSelect(
            "SELECT storage_id FROM scenario_explicit_items WHERE scenario_id = 'S'")
        .getSingle();
    expect(explicit.read<String>('storage_id'), 'old');

    final members = await db
        .customSelect(
            'SELECT tag_id, storage_id, path FROM video_tag_members ORDER BY tag_id')
        .get();
    expect(members, hasLength(2)); // the duplicated tag-1 row collapsed
    expect(members.map((r) => r.read<String>('storage_id')).toSet(), {'old'});

    final favorite = await db
        .customSelect('SELECT storage_id FROM favorites_table')
        .getSingle();
    expect(favorite.read<String>('storage_id'), 'old');

    final nav = await db
        .customSelect('SELECT current_storage_id FROM navigation_table')
        .getSingle();
    expect(nav.read<String>('current_storage_id'), 'old');

    final mapping = await db
        .customSelect('SELECT storage_id FROM bg_mappings_table')
        .getSingle();
    expect(mapping.read<String>('storage_id'), 'old');

    final segment = await db
        .customSelect('SELECT bg_storage_id FROM bg_mapping_segments_table')
        .getSingle();
    expect(segment.read<String>('bg_storage_id'), 'old');
  });

  test('the persisted occurrence JSON follows the merge', () async {
    await seed();
    await merge();

    final state = await db
        .customSelect(
            "SELECT current_playback_occurrence FROM scenario_state WHERE scenario_id = 'S'")
        .getSingle();
    final json = state.read<String>('current_playback_occurrence');
    expect(json, contains('"storageId":"old"'));
    expect(json, isNot(contains('"storageId":"new"')));
  });

  test('the loser scan bookkeeping is dropped (rebuilt on rescan)', () async {
    await seed();
    await merge();

    final states = await db.customSelect('SELECT COUNT(*) AS c FROM scan_states')
        .getSingle();
    final queue = await db.customSelect('SELECT COUNT(*) AS c FROM scan_queue')
        .getSingle();
    expect(states.read<int>('c'), 0);
    expect(queue.read<int>('c'), 0);
  });

  test('re-running after an interrupted merge is a no-op', () async {
    await seed();
    await merge();
    final second = await merge();

    expect(second.movedNodes, 0);
    expect(second.mergedNodes, 0);
    expect(second.droppedPhantoms, 0);
  });

  test('a legacy absolute spelling merges with its relative twin', () async {
    await seed();
    // Pre-fix scans could store the absolute form next to the relative one.
    await exec(
      "INSERT INTO media_nodes (storage_id, data_scope_id, path, name, "
      "node_kind, media_type, is_present) VALUES "
      "('new', 'new', 'E:/yb/d.mp4', 'd.mp4', 'file', 'video', 1)",
    );
    await exec(
      "INSERT INTO media_nodes (storage_id, data_scope_id, path, name, "
      "node_kind, media_type, is_present) VALUES "
      "('new', 'new', 'yb/d.mp4', 'd.mp4', 'file', 'video', 1)",
    );

    final stats = await merge();

    final rows = await dao.rowsInScope('old');
    expect(rows.where((r) => r.path.endsWith('d.mp4')), hasLength(1));
    expect(stats.movedNodes + stats.mergedNodes, greaterThanOrEqualTo(1));
  });

  test('a case-only base difference still merges (NTFS, one root)', () async {
    await seed();
    // The duplicate entry was added with the drive spelled in lower case. The
    // startup detection groups it (NTFS folds case), so the merge must accept
    // it too instead of logging "base mismatch" and doing nothing.
    final stats = await mergeDuplicateStorageGroup(
      StorageDuplicateGroup(
        survivor: _entry('old'),
        losers: <LocalStorage>[_entry('new', basePath: const <String>['e:'])],
      ),
      sweepMissingFiles: false,
      notifyRevisions: false,
      removeEntry: (_) async {},
    );

    expect(stats.mergedNodes, 3);
    expect(stats.movedNodes, 1);
    expect(await dao.rowsInScope('new'), isEmpty);
  });

  test('completion follows the row whose position is kept', () async {
    await seed();
    // 'old' watched yb/b.mp4 to the end first.
    await dao.updatePlaybackProgress(
      storageId: 'old',
      path: 'yb/b.mp4',
      positionMs: 120000,
      completed: true,
      lastPlayedAt: DateTime(2026, 1, 1),
    );
    // The duplicate entry re-opened it later and only got half-way.
    await dao.updatePlaybackProgress(
      storageId: 'new',
      path: 'yb/b.mp4',
      positionMs: 5000,
      completed: false,
      lastPlayedAt: DateTime(2026, 2, 2),
    );

    await merge();

    final merged = await row('old', 'yb/b.mp4');
    expect(merged.playbackPositionMs, 5000);
    expect(
      merged.playbackCompleted,
      isFalse,
      reason: 'a half-watched file must resume, not restart from the head',
    );
  });

  test('a finished later playthrough stays completed', () async {
    await seed();
    await dao.updatePlaybackProgress(
      storageId: 'old',
      path: 'yb/b.mp4',
      positionMs: 5000,
      completed: false,
      lastPlayedAt: DateTime(2026, 1, 1),
    );
    await dao.updatePlaybackProgress(
      storageId: 'new',
      path: 'yb/b.mp4',
      positionMs: 120000,
      completed: true,
      lastPlayedAt: DateTime(2026, 2, 2),
    );

    await merge();

    final merged = await row('old', 'yb/b.mp4');
    expect(merged.playbackPositionMs, 120000);
    expect(merged.playbackCompleted, isTrue);
  });

  test('case-variant references collapse on NTFS instead of duplicating',
      () async {
    await seed();
    // The same tag membership written through the duplicate entry with the
    // on-disk spelling in lower case. On NTFS both rows name ONE file, so the
    // merge must keep a single membership (a binary compare used to leave two).
    await exec(
      "INSERT INTO video_tag_members (tag_id, storage_id, path) "
      "VALUES (1, 'new', 'e:/yb/a.mp4')",
    );

    await merge();

    final members = await db
        .customSelect(
            'SELECT storage_id, path FROM video_tag_members WHERE tag_id = 1')
        .get();
    expect(members, hasLength(1));
    expect(members.single.read<String>('storage_id'), 'old');
  });

  test('a library source on a third storage is not swallowed', () async {
    await seed();
    // Both entries own a system library; the survivor's library also lists a
    // directory on ANOTHER storage. Re-homing the loser's source must only drop
    // the ones the survivor already has for the SAME storage.
    await exec(
      "INSERT INTO media_libs (id, name, lib_type) VALUES ('sys_old', 'Old', 0)",
    );
    await exec(
      "INSERT INTO media_libs (id, name, lib_type) VALUES ('sys_new', 'New', 0)",
    );
    await exec(
      "INSERT INTO media_lib_sources (library_id, storage_id, path) "
      "VALUES ('sys_old', 'third', 'yb')",
    );
    await exec(
      "INSERT INTO media_lib_sources (library_id, storage_id, path) "
      "VALUES ('sys_new', 'new', 'yb')",
    );

    await merge();

    final sources = await db
        .customSelect(
            'SELECT storage_id, path FROM media_lib_sources WHERE library_id = '
            "'sys_old' ORDER BY storage_id")
        .get();
    expect(
      sources.map(
          (r) => '${r.read<String>('storage_id')}:${r.read<String>('path')}'),
      <String>['old:yb', 'third:yb'],
    );
  });

  test('a moved row keeps the scan depth convention', () async {
    await seed();
    await merge();

    // Scans write `segments.length` (yb/c.mp4 = 2); the repair must agree.
    expect((await row('old', 'yb/c.mp4')).pathDepth, 2);
  });

  test('a base mismatch is refused instead of corrupting paths', () async {
    await seed();
    final stats = await mergeDuplicateStorageGroup(
      StorageDuplicateGroup(
        survivor: _entry('old'),
        losers: <LocalStorage>[
          LocalStorage(
            id: 'new',
            type: StorageType.internal,
            name: 'other base',
            basePath: const <String>['E:', 'other'],
            volumeId: 'vol:e9471df0',
          ),
        ],
      ),
      sweepMissingFiles: false,
      notifyRevisions: false,
      removeEntry: (_) async {},
    );

    expect(stats.movedNodes, 0);
    expect(await dao.rowsInScope('new'), isNotEmpty);
  });
}
