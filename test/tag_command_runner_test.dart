import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_members_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_pin_presets_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_view_states_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tags_dao.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/tag_play/model/domain/tag_command.dart';
import 'package:iris/features/tag_play/playback/tag_command_runner.dart';
import 'package:iris/features/tag_play/playback/tag_play_controller.dart';
import 'package:iris/features/tag_play/resolver/tag_view_resolver.dart';
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/path_conv.dart';

import 'helpers/sqlite3_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;
  late TagPlayRepository repo;

  setUpAll(() async {
    final bootstrap = AppDatabase(NativeDatabase.memory());
    await DbModule.init(bootstrap);
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useAppStore();
    await useAppStore().initialized;
    final app = useAppStore();
    app.set(app.state.copyWith(useMetadataSettings: true));
    final sc = usePlaybackScenarioStore();
    sc.set(sc.state.copyWith(activeScenarioId: 'sc'));
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = TagPlayRepository(
      tagsDao: VideoTagsDao(db),
      membersDao: VideoTagMembersDao(db),
      viewStatesDao: VideoTagViewStatesDao(db),
      presetsDao: VideoTagPinPresetsDao(db),
      db: db,
    );
  });

  tearDown(() async {
    final store = useTagPlayStore();
    store.set(store.state.copyWith(
      activeViewTagId: null,
      viewStackTagIds: const [],
      pinnedTagIds: const [],
    ));
    final app = useAppStore();
    app.set(app.state.copyWith(useScenarioDrivenPlayback: true));
    await db.close();
  });

  TagPlayController makeSwitcher() {
    return TagPlayController(
      repo: repo,
      resolverFactory: () => TagViewResolver(
        source: PassThroughSource(),
        repo: repo,
      ),
      noTagDelegate: _FakeNoTagDelegate(),
    );
  }

  Future<void> seedQueueFile() => usePlayQueueStore().update(
        playQueue: [
          PlayQueueItem(
            file: FileItem(
              storageId: 's1',
              name: 'a.mp4',
              path: ['a.mp4'],
              uri: 'a.mp4',
            ),
            index: 0,
          ),
        ],
        index: 0,
      );

  // Always inject a switcher: the runner consults it for the live-view
  // revalidate, and the global registry is not initialized under test.
  TagCommandRunner runner({TagPlayController? switcher}) =>
      TagCommandRunner(repo: repo, viewSwitcher: switcher ?? makeSwitcher());

  test('add applies to the sheet-order ordinal (pins first)', () async {
    final one = await repo.createTag(name: 'one');
    final two = await repo.createTag(name: 'two');
    await repo.createTag(name: 'three');
    await useTagPlayStore().setPinnedOrder([two.id]); // order: two, one, three
    await seedQueueFile();

    final outcome = await runner().run(
      const TagCommand(kind: TagCommandKind.add, ordinals: [1]),
    );

    expect(outcome.appliedTagIds, [two.id]);
    expect(outcome.appliedOrdinals, [1]);
    final members = await repo.membersOf(two.id);
    expect(members, hasLength(1));
    expect(members.first.path, contains('a.mp4'));
    expect(await repo.membersOf(one.id), isEmpty);
  });

  test('add applies to several ordinals in one command', () async {
    final one = await repo.createTag(name: 'one');
    final two = await repo.createTag(name: 'two');
    await seedQueueFile();

    final outcome = await runner().run(
      const TagCommand(kind: TagCommandKind.add, ordinals: [1, 2]),
    );

    expect(outcome.appliedTagIds..sort(), [one.id, two.id]..sort());
    expect(await repo.membersOf(one.id), hasLength(1));
    expect(await repo.membersOf(two.id), hasLength(1));
  });

  test('remove takes the media out of every addressed tag', () async {
    final one = await repo.createTag(name: 'one');
    final two = await repo.createTag(name: 'two');
    await repo
        .addMember(tagId: one.id, storageId: 's1', pathSegments: ['a.mp4']);
    await repo
        .addMember(tagId: two.id, storageId: 's1', pathSegments: ['a.mp4']);
    await seedQueueFile();

    await runner().run(
      const TagCommand(kind: TagCommandKind.remove, ordinals: [1, 2]),
    );

    expect(await repo.membersOf(one.id), isEmpty);
    expect(await repo.membersOf(two.id), isEmpty);
  });

  test('add 0 tags the current file in every tag', () async {
    final one = await repo.createTag(name: 'one');
    final two = await repo.createTag(name: 'two');
    final three = await repo.createTag(name: 'three');
    await seedQueueFile();

    final outcome = await runner().run(
      const TagCommand(kind: TagCommandKind.add, ordinals: [], allTags: true),
    );

    expect(outcome.appliedTagIds..sort(), [one.id, two.id, three.id]..sort());
    expect(outcome.unknownOrdinals, isEmpty);
    expect(await repo.membersOf(one.id), hasLength(1));
    expect(await repo.membersOf(two.id), hasLength(1));
    expect(await repo.membersOf(three.id), hasLength(1));
  });

  test('remove 0 takes the current file out of every tag', () async {
    final one = await repo.createTag(name: 'one');
    final two = await repo.createTag(name: 'two');
    for (final tag in [one, two]) {
      await repo
          .addMember(tagId: tag.id, storageId: 's1', pathSegments: ['a.mp4']);
    }
    await seedQueueFile();

    final outcome = await runner().run(
      const TagCommand(
          kind: TagCommandKind.remove, ordinals: [], allTags: true),
    );

    expect(outcome.appliedTagIds..sort(), [one.id, two.id]..sort());
    expect(await repo.membersOf(one.id), isEmpty);
    expect(await repo.membersOf(two.id), isEmpty);
  });

  test('add 0 is a silent no-op when no tags exist', () async {
    await seedQueueFile();

    final outcome = await runner().run(
      const TagCommand(kind: TagCommandKind.add, ordinals: [], allTags: true),
    );

    expect(outcome.appliedTagIds, isEmpty);
    expect(outcome.unknownOrdinals, isEmpty);
    expect(outcome.noCurrentFile, isFalse);
  });

  test('out-of-range ordinals are reported and skipped', () async {
    await repo.createTag(name: 'one');
    await seedQueueFile();

    final outcome = await runner().run(
      const TagCommand(kind: TagCommandKind.add, ordinals: [1, 9]),
    );

    expect(outcome.appliedOrdinals, [1]);
    expect(outcome.unknownOrdinals, [9]);
  });

  test('add reports noCurrentFile when the queue holds nothing taggable',
      () async {
    await repo.createTag(name: 'one');
    // An opened link: no storage id / path, so it cannot be tagged.
    await usePlayQueueStore().update(
      playQueue: [
        PlayQueueItem(
          file: FileItem(name: 'link', uri: 'https://example.com/a.mp4'),
          index: 0,
        ),
      ],
      index: 0,
    );

    final outcome = await runner().run(
      const TagCommand(kind: TagCommandKind.add, ordinals: [1]),
    );

    expect(outcome.noCurrentFile, isTrue);
    expect(outcome.appliedTagIds, isEmpty);
  });

  test('play enters the resolved tag view via the injected switcher', () async {
    final three = await repo.createTag(name: 'three');
    await useTagPlayStore().setPinnedOrder([three.id]);

    var at = DateTime.utc(2026, 8, 1);
    for (final p in ['x.mp4', 'y.mp4']) {
      await repo.addMember(
          tagId: three.id, storageId: 's1', pathSegments: [p], at: at);
      at = at.add(const Duration(hours: 1));
    }

    final switcher = makeSwitcher();
    // Production enters without an explicit id; bind here to bypass the global
    // store's async refresh race under test.
    switcher.bindScenario('sc');

    final outcome = await runner(switcher: switcher).run(
      const TagCommand(kind: TagCommandKind.play, ordinals: [1]),
    );

    expect(useTagPlayStore().state.activeViewTagId, three.id);
    expect(outcome.appliedTagIds, [three.id]);
  });

  test('play reports emptyView when the tag has no media in the scenario',
      () async {
    final one = await repo.createTag(name: 'one');
    // z.mp4 is not produced by PassThroughSource → the tag view resolves empty.
    await repo
        .addMember(tagId: one.id, storageId: 's1', pathSegments: ['z.mp4']);

    final switcher = makeSwitcher();
    switcher.bindScenario('sc');

    final outcome = await runner(switcher: switcher).run(
      const TagCommand(kind: TagCommandKind.play, ordinals: [1]),
    );

    expect(outcome.emptyView, isTrue);
    expect(outcome.appliedTagIds, isEmpty);
    expect(useTagPlayStore().state.activeViewTagId, isNull);
  });

  test('play 0 hands playback back to the no-tag list', () async {
    final one = await repo.createTag(name: 'one');
    final switcher = makeSwitcher();
    switcher.bindScenario('sc');
    await useTagPlayStore().setActiveView(one.id);
    expect(useTagPlayStore().state.activeViewTagId, one.id);

    final outcome = await runner(switcher: switcher).run(
      const TagCommand(
          kind: TagCommandKind.play, ordinals: [kTagCommandNoTagOrdinal]),
    );

    expect(outcome.playedNoTag, isTrue);
    expect(outcome.unknownOrdinals, isEmpty);
    expect(useTagPlayStore().state.activeViewTagId, isNull);
  });

  test('play reports viewSwitchingUnavailable without scenario playback',
      () async {
    await repo.createTag(name: 'three');
    final app = useAppStore();
    app.set(app.state.copyWith(useScenarioDrivenPlayback: false));

    final outcome = await runner().run(
      const TagCommand(kind: TagCommandKind.play, ordinals: [1]),
    );

    expect(outcome.viewSwitchingUnavailable, isTrue);
    expect(outcome.appliedTagIds, isEmpty);
  });
}

class _FakeNoTagDelegate implements NoTagDelegate {
  @override
  Future<PlaybackEntry?> current() async => null;

  @override
  Future<void> advanceEntry(PlaybackEntry entry,
      {bool autoplay = true, String? targetFileKey}) async {}

  @override
  Future<void> captureCurrentSegment() async {}
}

/// Source producing a fixed stream for the seeded members (x/y of s1),
/// filtered by membership keys exactly like production.
class PassThroughSource implements ScenarioEffectiveItemsSource {
  @override
  Future<List<EffectivePlaybackItem>> collect({
    required String scenarioId,
    Set<String>? mediaKeyFilter,
  }) async {
    const paths = ['/x.mp4', '/y.mp4'];
    final names = {'/x.mp4': 'x', '/y.mp4': 'y'};
    final all = [
      for (final p in paths)
        EffectivePlaybackItem(
          media: MediaNode.file(
            id: '-1',
            storageId: 's1',
            path: p.split('/').where((s) => s.isNotEmpty).toList(),
            name: names[p]!,
            mediaType: MediaType.video,
            isPresent: true,
          ),
          scenarioId: scenarioId,
          origins: const [],
          explicit: false,
          duplicated: false,
          available: true,
          virtualIndex: 0,
          occurrenceId: PlaybackOccurrenceId(storageId: 's1', path: p),
        ),
    ];
    if (mediaKeyFilter == null) return all;
    return all
        .where((e) => mediaKeyFilter.contains(
            canonicalKey(e.occurrenceId.storageId, e.occurrenceId.path)))
        .toList();
  }
}
