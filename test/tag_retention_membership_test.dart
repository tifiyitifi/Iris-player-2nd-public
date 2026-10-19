import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

import 'helpers/sqlite3_loader.dart';

/// The scenario tag source (and the indexed tag view) must honour a tag's OWN
/// retention window — the raw member DAO only knows an `addedAfter` cutoff, so
/// the cutoff has to be derived from the tag row before the read.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });

  tearDownAll(() async {
    await db.close();
  });

  group('tagMembershipCutoff', () {
    final now = DateTime(2026, 6, 1, 12);

    test('no retention keeps the caller window', () {
      final addedAfter = DateTime(2026, 5, 1);
      expect(
        tagMembershipCutoff(addedAfter: addedAfter, retention: null, now: now),
        addedAfter,
      );
      expect(
        tagMembershipCutoff(addedAfter: null, retention: null, now: now),
        isNull,
      );
    });

    test('a retention window alone becomes the cutoff', () {
      expect(
        tagMembershipCutoff(
          addedAfter: null,
          retention: const Duration(days: 2),
          now: now,
        ),
        now.subtract(const Duration(days: 2)),
      );
    });

    test('the STRICTER of the two wins', () {
      // A more recent caller window must not be widened back by the retention:
      // the old code returned `now - retention` unconditionally, so an
      // incremental read silently covered the whole retention span.
      final recent = now.subtract(const Duration(minutes: 30));
      expect(
        tagMembershipCutoff(
          addedAfter: recent,
          retention: const Duration(days: 7),
          now: now,
        ),
        recent,
      );
      // …and an older caller window must not resurrect expired members.
      final old = now.subtract(const Duration(days: 30));
      expect(
        tagMembershipCutoff(
          addedAfter: old,
          retention: const Duration(days: 7),
          now: now,
        ),
        now.subtract(const Duration(days: 7)),
      );
    });
  });

  test('members past the tag retention window are hidden', () async {
    final tag = await DbModule.tagPlayRepo.createTag(name: 'Retention');
    await DbModule.tagPlayRepo
        .updateTag(tag.copyWith(retention: const Duration(hours: 1)));

    final freshId = await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 's1:Anime/fresh.mp4',
      storageId: 's1',
      path: const ['Anime', 'fresh.mp4'],
      name: 'fresh.mp4',
      mediaType: MediaType.video,
    ));
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 's1:Anime/old.mp4',
      storageId: 's1',
      path: const ['Anime', 'old.mp4'],
      name: 'old.mp4',
      mediaType: MediaType.video,
    ));

    await DbModule.tagPlayRepo.addMember(
        tagId: tag.id, storageId: 's1', pathSegments: const ['Anime', 'fresh.mp4']);
    await DbModule.tagPlayRepo.addMember(
      tagId: tag.id,
      storageId: 's1',
      pathSegments: const ['Anime', 'old.mp4'],
      at: DateTime.now().subtract(const Duration(hours: 2)),
    );

    final ids = await PlaybackScenarioStore.activeTagMemberNodeIds(tag.id, null);
    expect(ids, [freshId], reason: 'the expired member must be hidden');
  });

  test('activeTagMemberNodeIdsByTag keeps the caller addedAfter on retention',
      () async {
    // The ByTag reader serves the shared intersection count. A retention tag must
    // apply the STRICTER of (now - retention) and the caller's incremental
    // window; dropping the caller's window widened an incremental read back to
    // the whole retention span.
    final tag = await DbModule.tagPlayRepo.createTag(name: 'ByTagRetention');
    await DbModule.tagPlayRepo
        .updateTag(tag.copyWith(retention: const Duration(days: 7)));

    final freshId = await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 's1:Anime/bytag-fresh.mp4',
      storageId: 's1',
      path: const ['Anime', 'bytag-fresh.mp4'],
      name: 'bytag-fresh.mp4',
      mediaType: MediaType.video,
    ));
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 's1:Anime/bytag-old.mp4',
      storageId: 's1',
      path: const ['Anime', 'bytag-old.mp4'],
      name: 'bytag-old.mp4',
      mediaType: MediaType.video,
    ));

    final now = DateTime.now();
    await DbModule.tagPlayRepo.addMember(
        tagId: tag.id,
        storageId: 's1',
        pathSegments: const ['Anime', 'bytag-fresh.mp4'],
        at: now);
    await DbModule.tagPlayRepo.addMember(
      tagId: tag.id,
      storageId: 's1',
      pathSegments: const ['Anime', 'bytag-old.mp4'],
      at: now.subtract(const Duration(hours: 2)),
    );

    final pairs = await PlaybackScenarioStore.activeTagMemberNodeIdsByTag(
      now.subtract(const Duration(minutes: 30)),
      repo: DbModule.tagPlayRepo,
      membersDao: DbModule.videoTagMembersDao,
    );
    expect(
      pairs.where((p) => p.tagId == tag.id).map((p) => p.nodeId),
      [freshId],
      reason: 'the 2h-old member is outside the caller window, not the 7d one',
    );
  });

  test('a tag with no retention keeps every member', () async {
    final tag = await DbModule.tagPlayRepo.createTag(name: 'Forever');
    final id = await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 's1:Anime/x.mp4',
      storageId: 's1',
      path: const ['Anime', 'x.mp4'],
      name: 'x.mp4',
      mediaType: MediaType.video,
    ));
    await DbModule.tagPlayRepo.addMember(
      tagId: tag.id,
      storageId: 's1',
      pathSegments: const ['Anime', 'x.mp4'],
      at: DateTime.now().subtract(const Duration(days: 365)),
    );

    final ids = await PlaybackScenarioStore.activeTagMemberNodeIds(tag.id, null);
    expect(ids, [id]);
  });
}
