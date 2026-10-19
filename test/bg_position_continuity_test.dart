import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_identity/store/use_app_identity_store.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/model/enum/tag_system_kind.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';

import 'helpers/sqlite3_loader.dart';

/// 副音 keeps NO media progress, but it DOES remember which file of its list it
/// was on — stored as the background scenario's occurrence (per entry), so a
/// restart continues with that same file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;

  FileItem fileOf(String name) => FileItem(
        storageId: 's1',
        path: ['Anime', name],
        name: name,
        uri: 'file:///Anime/$name',
      );

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
    // A scenario row must exist before the store's onReady refresh runs: its
    // initial-active pick reads the (otherwise empty) list.
    await DbModule.scenarioRepo.ensureSystemPlayingScenario();
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    await usePlaybackScenarioStore().ensureReady();
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useAppStore();
    await useAppStore().initialized;
    useStorageStore();
    await useStorageStore().initialized;
    useAppIdentityStore();
    useBackgroundPlaybackStore();
  });

  tearDownAll(() async {
    await db.close();
  });

  test('a restart resumes the remembered 副音 file', () async {
    final bg = useBackgroundPlaybackStore();
    // Deterministic order: the 副音 default is shuffle-ON (a random first
    // play), which would randomize the queue under the index assertions.
    bg.set(bg.state.copyWith(shuffle: false));

    final scenario = await ensureBackgroundPlaybackWorkspace();

    for (final n in ['a.mp4', 'b.mp4', 'c.mp4']) {
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: 's1:Anime/$n',
        storageId: 's1',
        path: ['Anime', n],
        name: n,
        mediaType: MediaType.video,
      ));
    }
    final tags = await DbModule.tagPlayRepo.ensureReservedTags();
    final tagId = tags
        .firstWhere(
            (t) => t.systemKind == TagSystemKind.backgroundVoiceCandidate)
        .id;
    for (final n in ['a.mp4', 'b.mp4', 'c.mp4']) {
      await DbModule.tagPlayRepo.addMember(
          tagId: tagId, storageId: 's1', pathSegments: ['Anime', n]);
    }

    final files = [fileOf('a.mp4'), fileOf('b.mp4'), fileOf('c.mp4')];

    await bg.enableWithQueue(files);
    expect(bg.state.currentIndex, 0);

    await bg.jumpTo(2);
    expect(bg.state.currentIndex, 2);
    // The position is remembered as the background scenario's OWN occurrence.
    final st = await DbModule.scenarioRepo.getState(scenario.id);
    expect(st?.currentPlaybackOccurrence?.path, contains('c.mp4'));

    // Simulate a restart: a fresh enable re-reads the remembered occurrence
    // and lands on the same file instead of the head.
    await bg.enableWithQueue(files);
    expect(bg.state.currentIndex, 2,
        reason: 'restart continues with the remembered file');
  });

  test('a restart resumes a SAF single-picked file by its uri identity',
      () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false));

    final scenario = await ensureBackgroundPlaybackWorkspace();

    // One ordinary file + one SAF single-picked file: the SAF row has an EMPTY
    // segment path and carries its identity in the uri. Landing back on index 1
    // (not the head) proves the resume key matched the uri, not the empty path.
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 's1:Saf/ordinary.mp4',
      storageId: 's1',
      path: const ['Saf', 'ordinary.mp4'],
      name: 'ordinary.mp4',
      mediaType: MediaType.video,
    ));
    const safUri =
        'content://com.android.externalstorage.documents/tree/primary%3ADownload/document/primary%3ADownload%2Fsaf.mp4';
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 's1:',
      storageId: 's1',
      path: const [],
      name: 'saf.mp4',
      mediaType: MediaType.video,
      uri: safUri,
    ));

    final tags = await DbModule.tagPlayRepo.ensureReservedTags();
    final tagId = tags
        .firstWhere(
            (t) => t.systemKind == TagSystemKind.backgroundVoiceCandidate)
        .id;
    await DbModule.tagPlayRepo.addMember(
        tagId: tagId,
        storageId: 's1',
        pathSegments: const ['Saf', 'ordinary.mp4']);
    await DbModule.tagPlayRepo.addMember(
        tagId: tagId, storageId: 's1', pathSegments: const []);

    final files = [
      FileItem(
        storageId: 's1',
        path: const ['Saf', 'ordinary.mp4'],
        name: 'ordinary.mp4',
        uri: 'file:///Saf/ordinary.mp4',
      ),
      FileItem(storageId: 's1', path: const [], name: 'saf.mp4', uri: safUri),
    ];

    await bg.enableWithQueue(files);
    await bg.jumpTo(1);
    expect(bg.state.currentIndex, 1);

    // Full fix: the SAF occurrence carries its document uri as the path, so the
    // identity round-trips instead of collapsing onto the empty path.
    final st = await DbModule.scenarioRepo.getState(scenario.id);
    expect(st?.currentPlaybackOccurrence?.path, contains('content://'),
        reason: 'the SAF occurrence must store its document uri as the path');

    // Simulate a restart: the remembered SAF occurrence must be found by its
    // uri-based media key, not the empty path.
    await bg.enableWithQueue(files);
    expect(bg.state.currentIndex, 1,
        reason: 'SAF restart must resume by the uri identity');
  });

  test('repeat is scenario-owned; shuffle is background-local', () async {
    final bg = useBackgroundPlaybackStore();
    final scenario = await ensureBackgroundPlaybackWorkspace();
    // The bg workspace loops by default (the scenario owns repeat).
    expect(scenario.repeatMode, Repeat.all);

    await bg.cycleBgRepeat(); // all -> one
    final stored = await DbModule.scenarioRepo.getScenario(scenario.id);
    expect(stored?.repeatMode, Repeat.one,
        reason: 'the scenario owns repeat');

    // 副音's stream IS the reserved tag's view, but its shuffle is a
    // background-local permutation: toggling it must NOT rewrite that shared
    // view state (the foreground tag browser of the same tag follows it).
    final tags = await DbModule.tagPlayRepo.ensureReservedTags();
    final tagId = tags
        .firstWhere(
            (t) => t.systemKind == TagSystemKind.backgroundVoiceCandidate)
        .id;
    final before = await DbModule.tagPlayRepo.stateOf(tagId);

    bg.set(bg.state.copyWith(shuffle: false, shuffleSeed: 0));
    await bg.toggleShuffle(); // off -> on (local)

    expect(bg.state.shuffle, isTrue);
    expect(bg.state.shuffleSeed, isNot(0),
        reason: 'the local shuffle carries its own seed');
    final after = await DbModule.tagPlayRepo.stateOf(tagId);
    expect(after?.order, before?.order,
        reason: 'the shared reserved-tag view must not be rewritten');
  });
}
