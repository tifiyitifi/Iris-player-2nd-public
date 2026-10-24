import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_source_provider.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/models/db/app_database.dart';

/// A rescan/probe rewrites `media_nodes` (duration, dimensions) but changes NO
/// definition row. The queue page read must therefore return the NEW metadata —
/// and the resolved-stream cache must not be able to serve the old snapshot.
///
/// Field regression this locks down: the indexed page read falls back to the
/// legacy walk (`resolvePage`) whenever the shared index is unavailable, and
/// that fallback used to DROP `playbackVersion` (defaulting to 0). The cache key
/// is derived from it, so the key never moved: after "Rescan source" the open
/// queue kept showing the pre-scan durations (and the pre-scan order) until the
/// process restarted and the in-memory cache was gone.
void main() {
  late AppDatabase db;
  late ScenarioRepository scenarioRepo;
  late MediaNodesDao nodesDao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    nodesDao = MediaNodesDao(db);
    scenarioRepo = ScenarioRepository(
      scenariosDao: ScenariosDao(db),
      sourcesDao: ScenarioSourcesDao(db),
      itemsDao: ScenarioExplicitItemsDao(db),
      excludesDao: ScenarioExcludesDao(db),
      statesDao: ScenarioStatesDao(db),
    );
  });

  tearDown(() async {
    await db.close();
  });

  /// A VM rule that matches nothing: merge rules being present is what ENABLES
  /// the resolved-stream cache (see `ScenarioResolver.resolvePage`), while an
  /// empty match keeps the flat list observable.
  VirtualMediaRule nonMatchingRule() => VirtualMediaRule(
        id: 'r1',
        name: 'R',
        matchMode: VmMatchMode.specifiedDirRecursive,
        paths: const ['NoMatch'],
        boundary: VmBoundaryMode.ignoreDirs,
        useDurationCap: false,
        useCountCap: true,
        maxItemCount: 10,
        enabled: true,
      );

  ScenarioResolver buildResolver() => ScenarioResolver(
        repo: scenarioRepo,
        nodeRepo: MediaNodeRepository(nodesDao),
        scopedMediaTypes: () => null,
        providers: {
          ScenarioSourceKind.file: const FileSourceProvider(),
        },
        vmRulesProvider: () async => [nonMatchingRule()],
        queueIndexDao: ScenarioQueueIndexDao(db),
      );

  Future<String> scenarioWithExplicitItem(int durationMs) async {
    final scenario = await scenarioRepo.createScenario(name: 'Playing');
    await scenarioRepo.addExplicitItem(
      scenarioId: scenario.id,
      storageId: 'st1',
      path: 'E:/media/clip.mp4',
    );
    await nodesDao.insertNode(
      MediaNode.file(
        id: 'st1:E:/media/clip.mp4',
        storageId: 'st1',
        path: const ['E:', 'media', 'clip.mp4'],
        name: 'clip.mp4',
        mediaType: MediaType.video,
        durationMs: durationMs,
        sizeInBytes: 1000,
      ),
    );
    return scenario.id;
  }

  Future<void> rewriteDuration(int durationMs) async {
    final rows = await MediaNodeRepository(nodesDao).updateFileMediaInfo(
      storageId: 'st1',
      path: 'E:/media/clip.mp4',
      durationMs: durationMs,
    );
    expect(rows, 1, reason: 'the row the queue reads must be the one rewritten');
  }

  int durationOf(List<EffectivePlaybackItem> items) => items.single.media
      .maybeMap(file: (f) => f.durationMs ?? 0, orElse: () => 0);

  group('resolved-stream cache vs. rewritten media metadata', () {
    test('playbackVersion bump reaches the INDEXED read fallback', () async {
      final id = await scenarioWithExplicitItem(347765);
      final resolver = buildResolver();

      // Priming read through the indexed entry point: no shared index exists
      // for this scenario, so it takes the legacy-walk fallback (the field
      // path) and caches the resolved stream.
      final first = await resolver.resolvePageIndexed(
        scenarioId: id,
        page: 0,
        pageSize: 10,
      );
      expect(durationOf(first.items), 347765);

      // The rescan's targeted probe rewrites the duration...
      await rewriteDuration(44153);

      // ...and the refresh announces it by bumping playbackVersion.
      final second = await resolver.resolvePageIndexed(
        scenarioId: id,
        page: 0,
        pageSize: 10,
        playbackVersion: 1,
      );
      expect(
        durationOf(second.items),
        44153,
        reason: 'the fallback must forward playbackVersion or the cache '
            'serves the pre-rescan snapshot forever',
      );
    });

    test('a media revision bump alone also invalidates the cache', () async {
      final id = await scenarioWithExplicitItem(347765);
      final resolver = buildResolver();

      final first = await resolver.resolvePageIndexed(
        scenarioId: id,
        page: 0,
        pageSize: 10,
      );
      expect(durationOf(first.items), 347765);

      await rewriteDuration(44153);

      // Same playbackVersion, different MEDIA generation: any path that
      // rewrites media_nodes without bumping the playback revision (a probe
      // write-back, a duration heal) must still be visible.
      final second = await resolver.resolvePageIndexed(
        scenarioId: id,
        page: 0,
        pageSize: 10,
        mediaRevision: 1,
      );
      expect(durationOf(second.items), 44153);
    });

    test('an unchanged generation still hits the cache', () async {
      final id = await scenarioWithExplicitItem(347765);
      final resolver = buildResolver();

      await resolver.resolvePageIndexed(
        scenarioId: id,
        page: 0,
        pageSize: 10,
      );
      await rewriteDuration(44153);

      // Documents the cache's purpose: without a revision signal the SAME
      // generation is allowed to be served from memory (the contract is that
      // every media-mutating path announces itself).
      final same = await resolver.resolvePageIndexed(
        scenarioId: id,
        page: 0,
        pageSize: 10,
      );
      expect(durationOf(same.items), 347765);
    });
  });
}
