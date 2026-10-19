import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart'
    show SortDirection;
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/actions/scenario_append_actions.dart';
import 'package:iris/features/scenario_playback/actions/scenario_override_actions.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/queue/paged_scenario_media_data_source.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

/// Regression: an override/append must refresh an ALREADY-OPEN scenario queue
/// view. The drop surfaces (top strip appends, the rest overrides) run without
/// leaving the player, so the previously-open dock/queue would otherwise keep
/// showing the pre-action items.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    await runZonedGuarded(() async {
      usePlayQueueStore();
      await usePlayQueueStore().initialized;
      useAppStore();
      await useAppStore().initialized;
    }, (Object e, StackTrace st) {});
  });

  setUp(() async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    await store.setActiveScenario(sys.id);
    await store.clearSources(sys.id);
    await store.clearExplicitItems(sys.id);
    await store.clearTemporaryExcludes(sys.id);
  });

  const storageId = 'st-r';

  Future<void> seed(String folder, String name) async {
    await DbModule.mediaNodesDao.deleteNode(storageId, '$folder/$name');
    final segments = '$folder/$name'.split('/');
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 'f:$storageId:$folder/$name',
      storageId: storageId,
      path: segments,
      name: segments.last,
      mediaType: MediaType.video,
    ));
  }

  test('override re-fetches an open queue and bumps the revision', () async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    await store.addSource(storageId: storageId, path: 'q1', recursive: true);
    await seed('q1', 'a.mp4');

    final ds = PagedScenarioMediaDataSource(scenarioId: sys.id);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(ds.totalItems, 1);
    final before = store.state.sourceScanRevision;

    await seed('q2', 'b.mp4');
    await seed('q2', 'c.mp4');
    await ScenarioOverrideActions.playSelectionInDefaultScenario(
      files: const [],
      directories: <ScenarioSourceSpec>[
        (
          storageId: storageId,
          path: 'q2',
          recursive: true,
          kind: ScenarioSourceKind.folder,
        ),
      ],
      sortField: ScenarioSortField.name,
      sortDirection: SortDirection.asc,
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(store.state.sourceScanRevision, greaterThan(before),
        reason: 'the override must signal an in-place queue re-fetch');
    expect(ds.totalItems, 2,
        reason: 'an open queue must show the overridden scope');
    ds.dispose();
  });

  test('append re-fetches an open queue and bumps the revision', () async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    await store.addSource(storageId: storageId, path: 'p1', recursive: true);
    await seed('p1', 'a.mp4');

    final ds = PagedScenarioMediaDataSource(scenarioId: sys.id);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(ds.totalItems, 1);
    final before = store.state.sourceScanRevision;

    await seed('p2', 'b.mp4');
    await seed('p2', 'c.mp4');
    await ScenarioAppendActions.appendToDefaultScenario(
      const [],
      directories: <ScenarioSourceSpec>[
        (
          storageId: storageId,
          path: 'p2',
          recursive: true,
          kind: ScenarioSourceKind.folder,
        ),
      ],
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(store.state.sourceScanRevision, greaterThan(before),
        reason: 'an append must signal an in-place queue re-fetch');
    expect(ds.totalItems, 3,
        reason: 'an open queue must show the existing + appended sources');
    ds.dispose();
  });
}
