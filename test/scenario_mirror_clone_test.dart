import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/commands/scenario_commands.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_state.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_lifetime.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/models/db/app_database.dart';

/// The multi-window neighbour feature mirrors a window's playback context by
/// CLONING its scenario definition + state into the new window's private
/// workspace (`ScenarioCommands.override`). The clone must reproduce the
/// effective queue EXACTLY — including the workspace-only (temporary) excludes
/// a user created by removing entries from the queue — and must carry the
/// current occurrence + ordering hint so the receiving window can step O(1).
void main() {
  late AppDatabase db;
  late ScenarioRepository repo;
  late ScenarioResolver resolver;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = ScenarioRepository(
      scenariosDao: ScenariosDao(db),
      sourcesDao: ScenarioSourcesDao(db),
      itemsDao: ScenarioExplicitItemsDao(db),
      excludesDao: ScenarioExcludesDao(db),
      statesDao: ScenarioStatesDao(db),
    );
    resolver = ScenarioResolver(
      repo: repo,
      nodeRepo: MediaNodeRepository(MediaNodesDao(db)),
      scopedMediaTypes: () => null,
    );
  });

  tearDown(() => db.close());

  MediaNode file(String path) => MediaNode.file(
        id: path,
        storageId: 'st1',
        path: path.split('/'),
        name: path.split('/').last,
        mediaType: MediaType.video,
      );

  Future<void> seed(List<String> paths) async {
    for (final path in paths) {
      await MediaNodesDao(db).insertNode(file(path));
    }
  }

  Future<List<String>> orderOf(String scenarioId) async {
    final page = await resolver.resolvePage(
      scenarioId: scenarioId,
      page: 0,
      pageSize: 50,
    );
    return page.items.map((e) => e.media.name).toList();
  }

  Future<Scenario> seededSource({required bool withTemporaryExclude}) async {
    await seed(['D:/a.mp4', 'D:/b.mp4', 'D:/c.mp4']);
    final source = await repo.createScenario(name: 'source');
    for (final path in ['D:/a.mp4', 'D:/b.mp4', 'D:/c.mp4']) {
      await repo.addExplicitItem(
        scenarioId: source.id,
        storageId: 'st1',
        path: path,
      );
    }
    if (withTemporaryExclude) {
      // What "remove from queue" writes: a workspace-only exclude.
      await repo.addExcludeRule(
        scenarioId: source.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: source.id,
          lifetime: ExcludeLifetime.temporary,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'D:/b.mp4',
        ),
      );
    }
    await repo.updateState(
      ScenarioState(
        scenarioId: source.id,
        currentPlaybackOccurrence: const PlaybackOccurrenceId(
          storageId: 'st1',
          path: 'D:/a.mp4',
        ),
        currentVirtualPos: 0,
      ),
    );
    return source;
  }

  test('the mirror clone reproduces the queue including temporary excludes',
      () async {
    final source = await seededSource(withTemporaryExclude: true);
    expect(await orderOf(source.id), ['a.mp4', 'c.mp4'],
        reason: 'sanity: the source queue already hides the removed entry');

    final target = await repo.createScenario(name: 'target');
    await ScenarioCommands.override(
      workspace: target,
      source: source,
      importPersistentExcludes: true,
      importTemporaryExcludes: true,
      repo: repo,
    );

    expect(await orderOf(target.id), await orderOf(source.id),
        reason: 'the receiving window must show the SAME playlist');
    expect(await orderOf(target.id), ['a.mp4', 'c.mp4']);

    final state = (await repo.getState(target.id))!;
    expect(state.currentPlaybackOccurrence?.storageId, 'st1');
    expect(state.currentPlaybackOccurrence?.path, 'D:/a.mp4',
        reason: 'the step in the new window starts from the source item');
    expect(state.currentVirtualPos, 0,
        reason: 'the ordering hint makes the locate O(1)');
  });

  test('without the temporary-exclude import the clone shows the removed entry',
      () async {
    final source = await seededSource(withTemporaryExclude: true);
    final target = await repo.createScenario(name: 'target');
    await ScenarioCommands.override(
      workspace: target,
      source: source,
      repo: repo,
    );

    expect(await orderOf(target.id), ['a.mp4', 'b.mp4', 'c.mp4'],
        reason: 'the pre-feature behaviour (persistent excludes only)');
  });

  test('a mirrored workspace can never sync back into the source window',
      () async {
    // `ScenarioCommands.override` always records the source as the origin, which
    // is correct for a scenario tile but WRONG for a mirror: the receiving
    // window would offer "sync back" and overwrite the other window's live
    // queue. The mirror therefore clears the marker right after the clone.
    final source = await seededSource(withTemporaryExclude: false);
    final target = await repo.createScenario(name: 'mirror');
    await ScenarioCommands.override(
      workspace: target,
      source: source,
      importTemporaryExcludes: true,
      repo: repo,
    );

    final mirrored = (await repo.getState(target.id))!;
    expect(mirrored.originScenarioId, source.id,
        reason: 'sanity: override records the origin');

    await repo.updateState(mirrored.copyWith(
      originScenarioId: null,
      importedAt: null,
      importVersion: null,
    ));

    expect(await ScenarioCommands.syncBack(workspace: target, repo: repo),
        isFalse,
        reason: 'no origin → sync-back must be disabled (E2)');
    expect(await orderOf(source.id), ['a.mp4', 'b.mp4', 'c.mp4'],
        reason: 'the source window queue is untouched');
  });
}
