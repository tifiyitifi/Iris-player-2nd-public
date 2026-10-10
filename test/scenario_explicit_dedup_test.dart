import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/actions/scenario_explicit_dedup_actions.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/sources/paged_scenario_sources_data_source.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

/// Integration coverage for the "remove redundant additions" cleanup: it must
/// delete ONLY the explicit items a directory / whole-storage source covers,
/// and leave sources, excludes and other explicit items untouched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
  });

  tearDownAll(() => db.close());

  const storageId = 'st-dedup';

  /// Creates a NON-active target scenario (active stays on the workspace) so the
  /// cleanup's `revalidateCurrent` branch is skipped and the assertion stays on
  /// the pure deletion behavior.
  Future<String> newTarget(PlaybackScenarioStore store) async {
    final sys = await store.ensureSystemPlayingScenario();
    final target = await store.createScenario('dedup-target');
    await store.setActiveScenario(sys.id);
    return target.id;
  }

  test('removeRedundant deletes only source-covered explicit items', () async {
    final store = usePlaybackScenarioStore();
    final id = await newTarget(store);

    await store.addSourceFor(id, storageId: storageId, path: 'shows', recursive: true);
    await store.addSourceFor(id, storageId: storageId, path: 'movies', recursive: false);

    // Covered (recursive dir, any depth).
    await store.addExplicitItemFor(scenarioId: id, storageId: storageId, path: 'shows/a.mp4');
    await store.addExplicitItemFor(scenarioId: id, storageId: storageId, path: 'shows/deep/b.mp4');
    // Covered (non-recursive dir, direct child only).
    await store.addExplicitItemFor(scenarioId: id, storageId: storageId, path: 'movies/d.mp4');
    // NOT covered (different storage / outside any source / nested under non-recursive).
    await store.addExplicitItemFor(scenarioId: id, storageId: storageId, path: 'other/c.mp4');
    await store.addExplicitItemFor(scenarioId: id, storageId: 'other', path: 'shows/x.mp4');
    await store.addExplicitItemFor(scenarioId: id, storageId: storageId, path: 'movies/sub/e.mp4');

    await DbModule.scenarioRepo.addExcludeRule(
      scenarioId: id,
      rule: ScenarioExcludeRule(
        id: 0,
        scenarioId: id,
        kind: ExcludeRuleKind.media,
        storageId: storageId,
        path: 'other/c.mp4',
      ),
    );

    expect(await ScenarioExplicitDedupActions.redundantCount(store, id), 3);

    final beforePlayback = store.state.playbackVersion;
    final removed = await ScenarioExplicitDedupActions.removeRedundant(store, id);
    expect(removed, 3);
    expect(store.state.playbackVersion, greaterThan(beforePlayback),
        reason: 'the cleanup notifies the playback layer');

    final remaining = await store.getExplicitItems(id);
    expect(
      remaining.map((e) => '${e.storageId}:${e.path}').toSet(),
      {
        '$storageId:other/c.mp4',
        'other:shows/x.mp4',
        '$storageId:movies/sub/e.mp4',
      },
    );
    // Untouched: sources and excludes.
    expect(await store.getSources(id), hasLength(2));
    expect(await store.getExcludeRules(id), hasLength(1));

    // Idempotent: a second run removes nothing.
    expect(await ScenarioExplicitDedupActions.removeRedundant(store, id), 0);
  });

  test('removeRedundant is a no-op when nothing is covered', () async {
    final store = usePlaybackScenarioStore();
    final id = await newTarget(store);

    await store.addSourceFor(id, storageId: storageId, path: 'shows', recursive: true);
    await store.addExplicitItemFor(scenarioId: id, storageId: storageId, path: 'movies/a.mp4');

    expect(await ScenarioExplicitDedupActions.redundantCount(store, id), 0);
    expect(await ScenarioExplicitDedupActions.removeRedundant(store, id), 0);
    expect(await store.getExplicitItems(id), hasLength(1));
  });

  test('sources data source flags only source-covered includes as redundant',
      () async {
    final store = usePlaybackScenarioStore();
    final id = await newTarget(store);

    await store.addSourceFor(id, storageId: storageId, path: 'shows', recursive: true);
    await store.addExplicitItemFor(
        scenarioId: id, storageId: storageId, path: 'shows/a.mp4');
    await store.addExplicitItemFor(
        scenarioId: id, storageId: storageId, path: 'movies/b.mp4');

    final ds = PagedScenarioSourcesDataSource(
      scenarioId: id,
      embeddedInStoragesDb: false,
    );
    addTearDown(ds.dispose);
    await ds.load();

    final includes = ds.items
        .where((i) => i.kind == ScenarioManageItemKind.include)
        .toList();
    expect(includes, hasLength(2));
    final covered = includes.singleWhere((i) => i.path == 'shows/a.mp4');
    final plain = includes.singleWhere((i) => i.path == 'movies/b.mp4');
    expect(ds.debugRedundantIncludeIds, {covered.includeId});
    expect(ds.debugRedundantIncludeIds, isNot(contains(plain.includeId)));
  });
}
