import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_query.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_state.dart';
import 'package:iris/features/scenario_playback/model/enum/duplicate_policy.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_lifetime.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_scope.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/commands/scenario_commands.dart';
import 'package:iris/features/scenario_playback/playback/playback_position_signal.dart';
import 'package:iris/features/scenario_playback/playback/playback_progress.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/migration/v9_migration.dart';
import 'package:iris/models/db/migration/v10_migration.dart';
import 'package:iris/utils/path_conv.dart';

void main() {
  group('Scenario-driven playback', () {
    late AppDatabase db;
    late ScenarioRepository scenarioRepo;
    late ScenarioResolver resolver;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      scenarioRepo = ScenarioRepository(
        scenariosDao: ScenariosDao(db),
        sourcesDao: ScenarioSourcesDao(db),
        itemsDao: ScenarioExplicitItemsDao(db),
        excludesDao: ScenarioExcludesDao(db),
        statesDao: ScenarioStatesDao(db),
      );
      resolver = ScenarioResolver(
        repo: scenarioRepo,
        nodeRepo: MediaNodeRepository(MediaNodesDao(db)),
        // Store-free env: pin the legacy playable-only semantics instead of
        // the browse-scope funnel (which needs an initialized AppStore).
        scopedMediaTypes: () => null,
      );
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> seedMedia(List<(String storageId, String path)> files) async {
      final dao = MediaNodesDao(db);
      for (final (storageId, path) in files) {
        await dao.insertNode(
          MediaNode.file(
            id: path,
            storageId: storageId,
            path: path.split('/'),
            name: path.split('/').last,
            mediaType: MediaType.video,
          ),
        );
      }
    }

    test('creates SystemPlayingScenario (type + version null)', () async {
      final scenario = await scenarioRepo.ensureSystemPlayingScenario();
      expect(scenario.type, ScenarioKind.systemPlaying);
      expect(scenario.version, isNull);

      final again = await scenarioRepo.ensureSystemPlayingScenario();
      expect(again.id, scenario.id);
    });

    test('resolves a folder source into effective items', () async {
      await seedMedia([
        ('st1', 'Anime/ep01.mp4'),
        ('st1', 'Anime/ep02.mp4'),
        ('st1', 'Anime/ep03.mp4'),
        ('st1', 'Other/clip.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Anime');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'Anime',
        recursive: true,
      );

      final page = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
      );

      expect(page.totalItems, 3);
      expect(page.items.length, 3);
      expect(
        page.items.map((e) => e.media.name),
        containsAll(['ep01.mp4', 'ep02.mp4', 'ep03.mp4']),
      );
      expect(page.items.every((e) => e.available), isTrue);
      expect(page.items.every((e) => !e.explicit), isTrue);
      expect(page.items.map((e) => e.virtualIndex), [0, 1, 2]);
    });

    test('sourceInternalFirst groups same-parent files contiguously', () async {
      await seedMedia([
        ('st1', 'root0.mp4'),
        ('st1', 'A/a.mp4'),
        ('st1', 'A/b.mp4'),
        ('st1', 'A/c.mp4'),
        ('st1', 'B/d.mp4'),
        ('st1', 'B/e.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Group');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: '',
        recursive: true,
      );

      // A fresh scenario defaults to sourceInternalFirst=false (flat order).
      expect(scenario.sourceInternalFirst, isFalse);

      // sourceInternalFirst=true → ORDER BY (parentPath asc, name asc):
      // root files (parentPath NULL) first, then A/*, then B/*.
      await scenarioRepo.updateScenario(
        scenario.copyWith(sourceInternalFirst: true),
      );
      final grouped = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 20,
      );
      expect(
        grouped.items.map((e) => e.media.name),
        ['root0.mp4', 'a.mp4', 'b.mp4', 'c.mp4', 'd.mp4', 'e.mp4'],
      );

      // sourceInternalFirst=false → plain name sort across all files.
      await scenarioRepo.updateScenario(
        (await scenarioRepo.getScenario(scenario.id))!
            .copyWith(sourceInternalFirst: false),
      );
      final flat = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 20,
      );
      expect(
        flat.items.map((e) => e.media.name),
        ['a.mp4', 'b.mp4', 'c.mp4', 'd.mp4', 'e.mp4', 'root0.mp4'],
      );

      // desc reverses BOTH the directory blocks and the field inside each
      // block (整体反序).
      await scenarioRepo.updateScenario(
        (await scenarioRepo.getScenario(scenario.id))!.copyWith(
          sourceInternalFirst: true,
          sortDirection: SortDirection.desc,
        ),
      );
      final reversed = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 20,
      );
      expect(
        reversed.items.map((e) => e.media.name),
        ['e.mp4', 'd.mp4', 'c.mp4', 'b.mp4', 'a.mp4', 'root0.mp4'],
      );
    });

    test('shuffle desc is the exact reverse of shuffle asc', () async {
      // FeistelShuffle cycle-walks on [0, totalCount), so it is a true
      // permutation for any size; 16 items verifies the reverse walk.
      await seedMedia([
        for (var i = 1; i <= 16; i++)
          ('st1', 'A/ep${i.toString().padLeft(2, '0')}.mp4'),
      ]);
      final scenario = await scenarioRepo.createScenario(name: 'Shuf');
      await scenarioRepo.addSource(
          scenarioId: scenario.id, storageId: 'st1', path: 'A', recursive: true);
      await scenarioRepo.updateScenario(
        (await scenarioRepo.getScenario(scenario.id))!.copyWith(
          order: PlaybackOrder.shuffled,
          sortDirection: SortDirection.asc,
        ),
      );
      await scenarioRepo.updateState(
        ScenarioState(scenarioId: scenario.id, shuffleSeed: 12345),
      );

      final asc = await resolver.resolvePage(
          scenarioId: scenario.id, page: 0, pageSize: 40);
      final ascNames = asc.items.map((e) => e.media.name).toList();
      expect(ascNames.length, 16);
      expect(ascNames.toSet().length, 16);

      await scenarioRepo.updateScenario(
        (await scenarioRepo.getScenario(scenario.id))!.copyWith(
          sortDirection: SortDirection.desc,
        ),
      );
      final desc = await resolver.resolvePage(
          scenarioId: scenario.id, page: 0, pageSize: 40);
      final descNames = desc.items.map((e) => e.media.name).toList();

      // desc = the same permutation walked backwards.
      expect(descNames, ascNames.reversed.toList());
    });

    test('shuffle covers every item exactly once even for a small queue', () async {
      // N=5 was a broken size for the old Feistel (collisions → duplicates and
      // a missing item); the cycle-walking engine must return all 5 exactly once.
      await seedMedia([
        ('st1', 'A/a.mp4'),
        ('st1', 'A/b.mp4'),
        ('st1', 'A/c.mp4'),
        ('st1', 'A/d.mp4'),
        ('st1', 'A/e.mp4'),
      ]);
      final scenario = await scenarioRepo.createScenario(name: 'SmallShuf');
      await scenarioRepo.addSource(
          scenarioId: scenario.id, storageId: 'st1', path: 'A', recursive: true);
      await scenarioRepo.updateScenario(
        (await scenarioRepo.getScenario(scenario.id))!.copyWith(
          order: PlaybackOrder.shuffled,
          sortDirection: SortDirection.asc,
        ),
      );
      await scenarioRepo.updateState(
        ScenarioState(scenarioId: scenario.id, shuffleSeed: 7),
      );

      final page = await resolver.resolvePage(
          scenarioId: scenario.id, page: 0, pageSize: 20);
      final names = page.items.map((e) => e.media.name).toList();
      expect(names.length, 5);
      expect(names.toSet(),
          {'a.mp4', 'b.mp4', 'c.mp4', 'd.mp4', 'e.mp4'});
    });

    test(
        'resolveItemByOccurrenceFor virtualIndex matches the shuffled position '
        '(asc, single-page queue)', () async {
      // Small queue (< pageSize) mirrors the reported single-page failure: the
      // recovered virtual index must be the SHUFFLED position, not the base one.
      await seedMedia([
        for (var i = 1; i <= 5; i++)
          ('st1', 'A/ep${i.toString().padLeft(2, '0')}.mp4'),
      ]);
      final scenario = await scenarioRepo.createScenario(name: 'LocAsc');
      await scenarioRepo.addSource(
          scenarioId: scenario.id, storageId: 'st1', path: 'A', recursive: true);
      await scenarioRepo.updateScenario(
        (await scenarioRepo.getScenario(scenario.id))!.copyWith(
          order: PlaybackOrder.shuffled,
          sortDirection: SortDirection.asc,
        ),
      );
      await scenarioRepo.updateState(
        ScenarioState(scenarioId: scenario.id, shuffleSeed: 12345),
      );

      final page = await resolver.resolvePage(
          scenarioId: scenario.id, page: 0, pageSize: 100);
      for (final displayed in page.items) {
        final recovered = await resolver.resolveItemByOccurrenceFor(
          scenarioId: scenario.id,
          occurrence: displayed.occurrenceId,
        );
        expect(recovered, isNotNull,
            reason: 'occurrence ${displayed.occurrenceId.occurrenceKey}');
        expect(recovered!.virtualIndex, displayed.virtualIndex,
            reason: 'base-space index must map to the shuffled position');
      }
    });

    test(
        'resolveItemByOccurrenceFor virtualIndex matches the reversed shuffled '
        'position (desc, single-page queue)', () async {
      await seedMedia([
        for (var i = 1; i <= 5; i++)
          ('st1', 'A/ep${i.toString().padLeft(2, '0')}.mp4'),
      ]);
      final scenario = await scenarioRepo.createScenario(name: 'LocDesc');
      await scenarioRepo.addSource(
          scenarioId: scenario.id, storageId: 'st1', path: 'A', recursive: true);
      await scenarioRepo.updateScenario(
        (await scenarioRepo.getScenario(scenario.id))!.copyWith(
          order: PlaybackOrder.shuffled,
          sortDirection: SortDirection.desc,
        ),
      );
      await scenarioRepo.updateState(
        ScenarioState(scenarioId: scenario.id, shuffleSeed: 12345),
      );

      final page = await resolver.resolvePage(
          scenarioId: scenario.id, page: 0, pageSize: 100);
      for (final displayed in page.items) {
        final recovered = await resolver.resolveItemByOccurrenceFor(
          scenarioId: scenario.id,
          occurrence: displayed.occurrenceId,
        );
        expect(recovered, isNotNull,
            reason: 'occurrence ${displayed.occurrenceId.occurrenceKey}');
        expect(recovered!.virtualIndex, displayed.virtualIndex,
            reason: 'desc (reverseShuffle) must map base index via '
                'total - 1 - inverse');
      }
    });

    test('pageSize larger than the historical 8-item cap returns full page',
        () async {
      await seedMedia([
        for (var i = 1; i <= 20; i++)
          ('st1', 'Anime/ep${i.toString().padLeft(2, '0')}.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Anime');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'Anime',
        recursive: true,
      );

      final page = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 50,
      );

      expect(page.totalItems, 20);
      expect(page.items.length, 20);
      expect(
          page.items.map((e) => e.virtualIndex), List.generate(20, (i) => i));
    });

    test('exclusion removes media and wins over explicit item', () async {
      await seedMedia([
        ('st1', 'Anime/ep01.mp4'),
        ('st1', 'Anime/ep02.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Anime');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'Anime',
        recursive: true,
      );
      await scenarioRepo.addExplicitItem(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'Anime/ep02.mp4',
      );
      await scenarioRepo.addExcludeRule(
        scenarioId: scenario.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: scenario.id,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'Anime/ep02.mp4',
        ),
      );

      final page = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
      );

      expect(page.items.map((e) => e.media.name), ['ep01.mp4']);
    });

    test('directory exclusion is recursive', () async {
      await seedMedia([
        ('st1', 'Anime/ep01.mp4'),
        ('st1', 'Anime/old/ep99.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Anime');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'Anime',
        recursive: true,
      );
      await scenarioRepo.addExcludeRule(
        scenarioId: scenario.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: scenario.id,
          kind: ExcludeRuleKind.directory,
          storageId: 'st1',
          path: 'Anime/old',
          recursive: true,
        ),
      );

      final page = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
      );

      expect(page.items.map((e) => e.media.name), ['ep01.mp4']);
    });

    test('source-scope exclude only prunes that source', () async {
      await seedMedia([
        ('st1', 'videos/ep01.mp4'),
        ('st1', 'videos/ep02.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Multi');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'videos',
        recursive: true,
      );

      final sources = await scenarioRepo.getSources(scenario.id);
      await scenarioRepo.addExcludeRule(
        scenarioId: scenario.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: scenario.id,
          scope: ExcludeScope.source,
          sourceId: sources.first.id,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'videos/ep02.mp4',
        ),
      );

      final page = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
      );

      expect(page.items.map((e) => e.media.name), ['ep01.mp4']);
    });

    test('allowDuplicate keeps duplicates with distinct occurrenceId',
        () async {
      await seedMedia([
        ('st1', 'videos/ep01.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Dup');
      await scenarioRepo.updateScenario(
        scenario.copyWith(duplicatePolicy: DuplicatePolicy.allowDuplicate),
      );
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'videos',
        recursive: true,
      );
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: '',
        recursive: true, // whole storage → same file again
      );

      final page = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
      );

      expect(page.items.length, 2);
      expect(page.items.map((e) => e.media.name), ['ep01.mp4', 'ep01.mp4']);
      expect(page.items.first.duplicated, isFalse);
      expect(page.items.last.duplicated, isTrue);
      expect(page.items[0].occurrenceId.occurrenceIndex, 0);
      expect(page.items[1].occurrenceId.occurrenceIndex, 1);
      expect(page.items[0].occurrenceId.occurrenceKey,
          isNot(page.items[1].occurrenceId.occurrenceKey));
    });

    test('deduplicate collapses duplicates by mediaRef', () async {
      await seedMedia([
        ('st1', 'videos/ep01.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Dedup');
      await scenarioRepo.updateScenario(
        scenario.copyWith(duplicatePolicy: DuplicatePolicy.deduplicate),
      );
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'videos',
        recursive: true,
      );
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: '',
        recursive: true,
      );

      final page = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
      );

      expect(page.items.length, 1);
      expect(page.items.first.media.name, 'ep01.mp4');
    });

    test('missing explicit item stays visible but unavailable', () async {
      await seedMedia([
        ('st1', 'Anime/ep01.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Anime');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'Anime',
        recursive: true,
      );
      await scenarioRepo.addExplicitItem(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'Anime/gone.mp4',
      );

      final page = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
      );

      final gone = page.items.firstWhere((e) => e.media.name == 'gone.mp4');
      expect(gone.explicit, isTrue);
      expect(gone.available, isFalse);
    });

    test('resolveItemByOccurrence recovers an item by storageId+path',
        () async {
      await seedMedia([
        ('st1', 'Anime/ep01.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Anime');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'Anime',
        recursive: true,
      );

      final item = await resolver.resolveItemByOccurrenceFor(
        scenarioId: scenario.id,
        occurrence: const PlaybackOccurrenceId(
            storageId: 'st1', path: 'Anime/ep01.mp4'),
      );

      expect(item, isNotNull);
      expect(item!.media.name, 'ep01.mp4');
      expect(item.mediaKey, 'st1:Anime/ep01.mp4');
    });

    test(
        'resolveItemByOccurrenceFor matches across slash conventions '
        '(files-paged single vs resolver double)', () async {
      // Node stored by _syncDbWithFilesystem with a leading-slash path string.
      // pathConv renders it back as `//storage/...` (double slash).
      final dao = MediaNodesDao(db);
      await dao.insertNode(MediaNode.file(
        id: 'x',
        storageId: 'st1',
        path: const ['/storage/emulated/0', 'A', 'ep01.mp4'],
        parentPath: '/storage/emulated/0/A',
        name: 'ep01.mp4',
        mediaType: MediaType.video,
      ));

      final scenario = await scenarioRepo.createScenario(name: 'A');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: '/storage/emulated/0/A',
        recursive: true,
      );

      // Files-paged persists the raw (single-slash) path; the resolver items
      // are double-slash. They must still resolve to the same occurrence.
      final item = await resolver.resolveItemByOccurrenceFor(
        scenarioId: scenario.id,
        occurrence: const PlaybackOccurrenceId(
          storageId: 'st1',
          path: '/storage/emulated/0/A/ep01.mp4',
        ),
      );

      expect(item, isNotNull);
      expect(item!.media.name, 'ep01.mp4');
    });

    test('temporary exclude lifecycle (repo + resolver)', () async {
      await seedMedia([
        ('st1', 'Anime/ep01.mp4'),
        ('st1', 'Anime/ep02.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Anime');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'Anime',
        recursive: true,
      );
      await scenarioRepo.addExcludeRule(
        scenarioId: scenario.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: scenario.id,
          lifetime: ExcludeLifetime.temporary,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'Anime/ep02.mp4',
        ),
      );

      var page = await resolver.resolvePage(
          scenarioId: scenario.id, page: 0, pageSize: 10);
      expect(page.items.map((e) => e.media.name), ['ep01.mp4']);

      await scenarioRepo.clearTemporaryExcludes(scenario.id);
      page = await resolver.resolvePage(
          scenarioId: scenario.id, page: 0, pageSize: 10);
      expect(page.items.length, 2);
    });

    test('F1: same logical exclude rule only once (repo upsert)', () async {
      final scenario = await scenarioRepo.createScenario(name: 'F1');
      await scenarioRepo.addExcludeRule(
        scenarioId: scenario.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: scenario.id,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'a.mp4',
        ),
      );
      await scenarioRepo.addExcludeRule(
        scenarioId: scenario.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: scenario.id,
          lifetime: ExcludeLifetime
              .temporary, // different lifetime → same logical rule
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'a.mp4',
        ),
      );
      final rules = await scenarioRepo.getExcludeRules(scenario.id);
      expect(rules.length, 1);
      expect(rules.first.lifetime, ExcludeLifetime.temporary);
    });

    test('EffectivePlaybackItem runtime model', () {
      final item = EffectivePlaybackItem(
        media: MediaNode.file(
          id: '1',
          storageId: 'st1',
          path: const ['a.mp4'],
          name: 'a.mp4',
          mediaType: MediaType.video,
        ),
        scenarioId: 'ctx',
        explicit: true,
        duplicated: true,
        virtualIndex: 0,
        occurrenceId:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'a.mp4'),
      );
      expect(item.mediaKey, 'st1:a.mp4');
      expect(item.explicit, isTrue);
      expect(item.duplicated, isTrue);
    });

    test('non-recursive root source resolves root-level files only', () async {
      await seedMedia([
        ('st1', 'ep01.mp4'),
        ('st1', 'sub/ep02.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Root');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: '',
        recursive: false,
      );

      final page = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
      );

      expect(page.items.map((e) => e.media.name), ['ep01.mp4']);
    });

    test('recursive root source resolves the whole storage', () async {
      await seedMedia([
        ('st1', 'ep01.mp4'),
        ('st1', 'sub/ep02.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Root');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: '',
        recursive: true,
      );

      final page = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
      );

      expect(page.items.length, 2);
    });

    test('rescan-preserving progress upsert keeps progress', () async {
      final dao = MediaNodesDao(db);
      await seedMedia([
        ('st1', 'a.mp4'),
      ]);
      await dao.updatePlaybackProgress(
        storageId: 'st1',
        path: 'a.mp4',
        positionMs: 12345,
        completed: true,
        playCount: 3,
      );

      // Simulate a rescan re-upserting the same node (same path) without
      // touching the progress fields.
      await dao.upsertNode(
        MediaNode.file(
          id: 'a.mp4',
          storageId: 'st1',
          path: const ['a.mp4'],
          name: 'a.mp4',
          mediaType: MediaType.video,
        ),
      );

      final row = await dao.getByPath('st1', 'a.mp4');
      final node = MediaNodeDriftAdapter.fromDb(row!);
      final file = node.maybeMap(file: (f) => f, orElse: () => null);
      expect(file!.playbackPositionMs, 12345);
      expect(file.playbackCompleted, isTrue);
      expect(file.playCount, 3);
    });
    test('Override clears ALL workspace excludes and sets origin (E1/F2/D2)',
        () async {
      final sys = await scenarioRepo.ensureSystemPlayingScenario();
      final source = await scenarioRepo.createScenario(name: 'Anime');

      // Workspace already holds temp + persistent excludes (should all be cleared).
      await scenarioRepo.addExcludeRule(
        scenarioId: sys.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: sys.id,
          lifetime: ExcludeLifetime.temporary,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'a.mp4',
        ),
      );
      await scenarioRepo.addExcludeRule(
        scenarioId: sys.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: sys.id,
          lifetime: ExcludeLifetime.persistent,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'b.mp4',
        ),
      );
      // Source has its own persistent exclude (should be imported by default).
      await scenarioRepo.addExcludeRule(
        scenarioId: source.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: source.id,
          lifetime: ExcludeLifetime.persistent,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'c.mp4',
        ),
      );

      await ScenarioCommands.override(
          workspace: sys, source: source, repo: scenarioRepo);

      final wsRules = await scenarioRepo.getExcludeRules(sys.id);
      expect(wsRules.map((r) => r.path),
          ['c.mp4']); // only source's persistent imported
      final state = await scenarioRepo.getState(sys.id);
      expect(state!.originScenarioId, source.id); // F2
      expect(state.importVersion, source.version);
    });

    test('Append keeps originScenarioId (F2)', () async {
      final sys = await scenarioRepo.ensureSystemPlayingScenario();
      final a = await scenarioRepo.createScenario(name: 'A');
      final b = await scenarioRepo.createScenario(name: 'B');

      await ScenarioCommands.override(
          workspace: sys, source: a, repo: scenarioRepo);
      await ScenarioCommands.append(
          workspace: sys, source: b, repo: scenarioRepo);

      final state = await scenarioRepo.getState(sys.id);
      expect(state!.originScenarioId, a.id); // kept A, not replaced by B
    });

    test('Save As copies persistent excludes only, temp ignored (D2)',
        () async {
      final sys = await scenarioRepo.ensureSystemPlayingScenario();
      await scenarioRepo.addSource(
          scenarioId: sys.id, storageId: 'st1', path: 'Anime', recursive: true);
      await scenarioRepo.addExplicitItem(
          scenarioId: sys.id, storageId: 'st1', path: 'Anime/ep01.mp4');
      await scenarioRepo.addExcludeRule(
        scenarioId: sys.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: sys.id,
          lifetime: ExcludeLifetime.persistent,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'a.mp4',
        ),
      );
      await scenarioRepo.addExcludeRule(
        scenarioId: sys.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: sys.id,
          lifetime: ExcludeLifetime.temporary,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'b.mp4',
        ),
      );

      final saved =
          await ScenarioCommands.saveAs(workspace: sys, repo: scenarioRepo);

      final rules = await scenarioRepo.getExcludeRules(saved.id);
      expect(rules.map((r) => r.path), ['a.mp4']);
      final sources = await scenarioRepo.getSources(saved.id);
      expect(sources.length, 1);
      final items = await scenarioRepo.getExplicitItems(saved.id);
      expect(items.length, 1);
      final savedScenario = await scenarioRepo.getScenario(saved.id);
      expect(savedScenario!.version, 0);
    });

    test('Save As copies the full Definition config (D1)', () async {
      final sys = await scenarioRepo.ensureSystemPlayingScenario();
      await scenarioRepo.updateScenario(sys.copyWith(
        sortField: ScenarioSortField.durationMs,
        sortDirection: SortDirection.desc,
        originalSortField: ScenarioSortField.durationMs,
        duplicatePolicy: DuplicatePolicy.deduplicate,
        sourceInternalFirst: false,
      ));
      final updatedWorkspace = (await scenarioRepo.getScenario(sys.id))!;

      final saved = await ScenarioCommands.saveAs(
          workspace: updatedWorkspace, repo: scenarioRepo);
      final s = await scenarioRepo.getScenario(saved.id);
      expect(s!.sortField, ScenarioSortField.durationMs);
      expect(s.sortDirection, SortDirection.desc);
      expect(s.originalSortField, ScenarioSortField.durationMs);
      expect(s.duplicatePolicy, DuplicatePolicy.deduplicate);
      expect(s.sourceInternalFirst, isFalse);
    });

    test('SyncBack disabled when originScenarioId is null (E2)', () async {
      final sys = await scenarioRepo.ensureSystemPlayingScenario();
      final ok =
          await ScenarioCommands.syncBack(workspace: sys, repo: scenarioRepo);
      expect(ok, isFalse);
    });

    test('SyncBack writes workspace back to origin and bumps version (E2/A6)',
        () async {
      final sys = await scenarioRepo.ensureSystemPlayingScenario();
      final source = await scenarioRepo.createScenario(name: 'Anime');
      await scenarioRepo.addSource(
          scenarioId: source.id,
          storageId: 'st1',
          path: 'Anime',
          recursive: true);
      await ScenarioCommands.override(
          workspace: sys, source: source, repo: scenarioRepo);

      // Modify the workspace after override.
      await scenarioRepo.addSource(
          scenarioId: sys.id, storageId: 'st1', path: 'Other', recursive: true);

      final ok =
          await ScenarioCommands.syncBack(workspace: sys, repo: scenarioRepo);
      expect(ok, isTrue);

      final originSources = await scenarioRepo.getSources(source.id);
      expect(originSources.length, 2); // Anime + Other synced back
      final origin = await scenarioRepo.getScenario(source.id);
      expect(origin!.version, 1); // bumped
    });

    test('v8→v9 migration rebuilds scenario tables (B1/D1/D4/E4/F1)', () async {
      // Simulate a v8 database: drop the v9 tables, create v8-shaped ones and
      // seed data, then run MigrationV9.
      await db.customStatement('DROP TABLE IF EXISTS scenario_state');
      await db.customStatement('DROP TABLE IF EXISTS scenario_excludes');
      await db.customStatement('DROP TABLE IF EXISTS scenario_explicit_items');
      await db.customStatement('DROP TABLE IF EXISTS scenario_sources');
      await db.customStatement('DROP TABLE IF EXISTS scenario');

      await db.customStatement('''
        CREATE TABLE playback_scenarios (
          id TEXT PRIMARY KEY, name TEXT NOT NULL,
          is_system_default INTEGER NOT NULL DEFAULT 0, created_at TEXT, updated_at TEXT
        )
      ''');
      await db.customStatement('''
        CREATE TABLE playback_scenario_states (
          scenario_id TEXT PRIMARY KEY, current_storage_id TEXT, current_path TEXT,
          "order" TEXT NOT NULL, shuffle_seed INTEGER, shuffle_version INTEGER NOT NULL DEFAULT 0,
          shuffle_item_count INTEGER NOT NULL DEFAULT 0, repeat_mode TEXT NOT NULL,
          sort_field TEXT NOT NULL, sort_direction TEXT NOT NULL, last_active_at TEXT
        )
      ''');
      await db.customStatement('''
        CREATE TABLE scenario_sources (
          id INTEGER PRIMARY KEY AUTOINCREMENT, scenario_id TEXT NOT NULL,
          storage_id TEXT NOT NULL, path TEXT NOT NULL DEFAULT '',
          recursive INTEGER NOT NULL DEFAULT 0, source_kind TEXT, created_at TEXT,
          UNIQUE(scenario_id, storage_id, path)
        )
      ''');
      await db.customStatement('''
        CREATE TABLE scenario_explicit_includes (
          id INTEGER PRIMARY KEY AUTOINCREMENT, scenario_id TEXT NOT NULL,
          storage_id TEXT NOT NULL, path TEXT NOT NULL, media_id INTEGER, created_at TEXT,
          UNIQUE(scenario_id, storage_id, path)
        )
      ''');
      await db.customStatement('''
        CREATE TABLE scenario_exclude_rules (
          id INTEGER PRIMARY KEY AUTOINCREMENT, scenario_id TEXT NOT NULL,
          kind TEXT NOT NULL, storage_id TEXT NOT NULL, path TEXT NOT NULL,
          recursive INTEGER NOT NULL DEFAULT 0, created_at TEXT,
          UNIQUE(scenario_id, kind, storage_id, path)
        )
      ''');
      await db.customStatement('''
        CREATE TABLE media_playback_progress (
          storage_id TEXT NOT NULL, path TEXT NOT NULL, position_ms INTEGER NOT NULL DEFAULT 0,
          completed INTEGER NOT NULL DEFAULT 0, last_played_at TEXT,
          play_count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (storage_id, path)
        )
      ''');

      await db.customStatement(
        "INSERT INTO playback_scenarios (id, name, is_system_default) VALUES ('sys', 'Playing', 1)",
      );
      await db.customStatement(
        "INSERT INTO playback_scenarios (id, name, is_system_default) VALUES ('u1', 'Anime', 0)",
      );
      await db.customStatement(
        'INSERT INTO playback_scenario_states (scenario_id, current_storage_id, current_path, '
        '"order", shuffle_seed, shuffle_version, shuffle_item_count, repeat_mode, sort_field, sort_direction) '
        "VALUES ('u1', 'st1', 'Anime/ep01.mp4', 'sequential', NULL, 0, 0, 'none', 'name', 'asc')",
      );
      await db.customStatement(
        "INSERT INTO scenario_sources (scenario_id, storage_id, path, recursive) VALUES ('u1', 'st1', 'Anime', 1)",
      );
      await db.customStatement(
        "INSERT INTO scenario_explicit_includes (scenario_id, storage_id, path) VALUES ('u1', 'st1', 'Anime/ep02.mp4')",
      );
      await db.customStatement(
        "INSERT INTO scenario_exclude_rules (scenario_id, kind, storage_id, path) VALUES ('u1', 'media', 'st1', 'Anime/ep03.mp4')",
      );
      await db.customStatement(
        "INSERT INTO media_playback_progress (storage_id, path, position_ms, play_count) "
        "VALUES ('st1', 'Anime/ep01.mp4', 5000, 2)",
      );
      await db.customStatement(
        "INSERT INTO media_nodes (storage_id, path, parent_path, path_depth, name, normalized_name, node_kind, media_type) "
        "VALUES ('st1', 'Anime/ep01.mp4', 'Anime', 2, 'ep01.mp4', 'ep01.mp4', 'file', 'video')",
      );

      await MigrationV9(db).run(drift.Migrator(db));

      final scenarios = await db
          .customSelect('SELECT id, type, version, sort_field FROM scenario')
          .get();
      expect(scenarios.length, 2);
      final sys = scenarios.firstWhere((r) => r.read<String>('id') == 'sys');
      final user = scenarios.firstWhere((r) => r.read<String>('id') == 'u1');
      expect(sys.read<String>('type'), 'systemPlaying');
      expect(sys.read<int?>('version'), isNull); // E4
      expect(user.read<String>('type'), 'userSaved');
      expect(user.read<int>('version'), 0);
      expect(user.read<String>('sort_field'), 'name'); // D1 config JOIN

      final sources = await db.customSelect(
        'SELECT sort_order FROM scenario_sources WHERE scenario_id = ?',
        variables: [drift.Variable('u1')],
      ).get();
      expect(sources.first.read<int>('sort_order'), 1);

      final items = await db.customSelect(
        'SELECT batch_id, add_order, ui_sort_key FROM scenario_explicit_items WHERE scenario_id = ?',
        variables: [drift.Variable('u1')],
      ).get();
      expect(items.length, 1);
      expect(items.first.read<String>('batch_id'), 'u1');
      expect(items.first.read<int>('add_order'), 1);

      final excludes = await db.customSelect(
        'SELECT scope, lifetime, source_id FROM scenario_excludes WHERE scenario_id = ?',
        variables: [drift.Variable('u1')],
      ).get();
      expect(excludes.length, 1);
      expect(excludes.first.read<String>('scope'), 'scenario');
      expect(excludes.first.read<String>('lifetime'), 'persistent');
      expect(excludes.first.read<int?>('source_id'), isNull);

      final states = await db
          .customSelect(
              'SELECT current_playback_occurrence FROM scenario_state')
          .get();
      final occRaw = states.first.read<String>('current_playback_occurrence');
      expect(occRaw, contains('"storageId":"st1"'));
      expect(occRaw, contains('"path":"Anime/ep01.mp4"'));
      expect(occRaw, contains('"occurrenceIndex":0'));

      final progress = await db.customSelect(
        'SELECT playback_position_ms, play_count FROM media_nodes WHERE path = ?',
        variables: [drift.Variable('Anime/ep01.mp4')],
      ).get();
      expect(progress.first.read<int>('playback_position_ms'), 5000);
      expect(progress.first.read<int>('play_count'), 2);

      expect(
          await db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='media_playback_progress'",
              )
              .get(),
          isEmpty);
    });

    test('sort field reorders the effective queue', () async {
      await seedMedia([
        ('st1', 'A/ep03.mp4'),
        ('st1', 'A/ep01.mp4'),
        ('st1', 'A/ep02.mp4'),
      ]);
      final dao = MediaNodesDao(db);
      await dao.updateFileDuration('st1', 'A/ep01.mp4', 3000);
      await dao.updateFileDuration('st1', 'A/ep02.mp4', 1000);
      await dao.updateFileDuration('st1', 'A/ep03.mp4', 2000);

      final scenario = await scenarioRepo.createScenario(name: 'Sort');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'A',
        recursive: true,
      );

      // Default: name asc.
      var page = await resolver.resolvePage(
          scenarioId: scenario.id, page: 0, pageSize: 10);
      expect(page.items.map((e) => e.media.name).toList(),
          ['ep01.mp4', 'ep02.mp4', 'ep03.mp4']);

      // durationMs desc → ep01 (3000), ep03 (2000), ep02 (1000).
      await scenarioRepo.updateScenario(scenario.copyWith(
        sortField: ScenarioSortField.durationMs,
        sortDirection: SortDirection.desc,
      ));
      page = await resolver.resolvePage(
          scenarioId: scenario.id, page: 0, pageSize: 10);
      expect(page.items.map((e) => e.media.name).toList(),
          ['ep01.mp4', 'ep03.mp4', 'ep02.mp4']);
    });

    test('createScenario leaves originalSortField null until a real add', () async {
      final scenario = await scenarioRepo.createScenario(name: 'Orig');
      expect(scenario.originalSortField, isNull);
    });

    test('Override copies the source original sort rule (D2)', () async {
      final sys = await scenarioRepo.ensureSystemPlayingScenario();
      final source = await scenarioRepo.createScenario(name: 'Src');
      await scenarioRepo.updateScenario(source.copyWith(
        sortField: ScenarioSortField.sizeInBytes,
        sortDirection: SortDirection.desc,
        originalSortField: ScenarioSortField.sizeInBytes,
      ));
      final updatedSource = await scenarioRepo.getScenario(source.id);

      await ScenarioCommands.override(
          workspace: sys, source: updatedSource!, repo: scenarioRepo);

      final ws = await scenarioRepo.getScenario(sys.id);
      expect(ws!.originalSortField, ScenarioSortField.sizeInBytes);
    });

    test('multi-select rule: dir sources resolve before explicit files',
        () async {
      await seedMedia([
        ('st1', 'D1/a.mp4'),
        ('st1', 'D1/b.mp4'),
        ('st1', 'f1.mp4'),
        ('st1', 'f2.mp4'),
      ]);

      final scenario = await scenarioRepo.createScenario(name: 'Multi');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'D1',
        recursive: true,
      );
      await scenarioRepo.addExplicitItem(
          scenarioId: scenario.id, storageId: 'st1', path: 'f1.mp4');
      await scenarioRepo.addExplicitItem(
          scenarioId: scenario.id, storageId: 'st1', path: 'f2.mp4');
      await scenarioRepo.updateScenario(
          (await scenarioRepo.getScenario(scenario.id))!
              .copyWith(sortField: ScenarioSortField.name));

      final page = await resolver.resolvePage(
          scenarioId: scenario.id, page: 0, pageSize: 10);
      // Selected directory contents first (sorted), then explicit files in
      // selection order.
      expect(page.items.map((e) => e.media.name).toList(),
          ['a.mp4', 'b.mp4', 'f1.mp4', 'f2.mp4']);
    });

    test('v9→v10 migration adds scenario.original_sort_field', () async {
      await db.customStatement('DROP TABLE IF EXISTS scenario');
      await db.customStatement('''
        CREATE TABLE scenario (
          id TEXT PRIMARY KEY, name TEXT NOT NULL,
          description TEXT, type TEXT, version INTEGER,
          sort_field TEXT, sort_direction TEXT, "order" TEXT,
          duplicate_policy TEXT, repeat_mode TEXT, created_at TEXT, updated_at TEXT
        )
      ''');
      await db.customStatement(
        "INSERT INTO scenario (id, name, type, sort_field) VALUES ('s1', 'A', 'userSaved', 'name')",
      );

      await MigrationV10(db).run(drift.Migrator(db));

      final cols = await db.customSelect('PRAGMA table_info(scenario)').get();
      expect(cols.any((c) => c.read<String>('name') == 'original_sort_field'),
          isTrue);
      final row = await db.customSelect(
        'SELECT original_sort_field FROM scenario WHERE id = ?',
        variables: [drift.Variable('s1')],
      ).getSingle();
      expect(row.read<String?>('original_sort_field'), isNull);
    });

    test('folder source excludes non-media (unknown) and directory nodes',
        () async {
      final dao = MediaNodesDao(db);
      await seedMedia([
        ('st1', 'Anime/ep01.mp4'),
        ('st1', 'Anime/ep02.mp4'),
      ]);
      // A non-media file (e.g. JSON) recorded as a file node.
      await dao.insertNode(
        MediaNode.file(
          id: 'st1:Anime/notes.json',
          storageId: 'st1',
          path: 'Anime/notes.json'.split('/'),
          parentPath: 'Anime',
          pathDepth: 2,
          name: 'notes.json',
          mediaType: MediaType.unknown,
        ),
      );
      // A sub-directory node — must never enter the play queue.
      await dao.insertNode(
        MediaNode.directory(
          id: 'st1:Anime/subdir',
          storageId: 'st1',
          path: 'Anime/subdir'.split('/'),
          parentPath: 'Anime',
          pathDepth: 2,
          name: 'subdir',
        ),
      );

      final scenario = await scenarioRepo.createScenario(name: 'Anime');
      await scenarioRepo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'Anime',
        recursive: true,
      );

      final page = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
      );

      expect(page.totalItems, 2);
      expect(
        page.items.map((e) => e.media.name),
        containsAll(['ep01.mp4', 'ep02.mp4']),
      );
      expect(
        page.items.map((e) => e.media.name),
        isNot(contains('notes.json')),
      );
      expect(
        page.items.map((e) => e.media.name),
        isNot(contains('subdir')),
      );
    });

    test('getPagedNodes mediaTypes filter restricts to playable types',
        () async {
      final dao = MediaNodesDao(db);
      for (final (name, type) in [
        ('v.mp4', MediaType.video),
        ('a.mp3', MediaType.audio),
        ('notes.txt', MediaType.unknown),
      ]) {
        await dao.insertNode(
          MediaNode.file(
            id: 'st1:V/$name',
            storageId: 'st1',
            path: 'V/$name'.split('/'),
            parentPath: 'V',
            pathDepth: 2,
            name: name,
            mediaType: type,
          ),
        );
      }

      final result = await dao.getPagedNodes(
        MediaNodePageQuery(
          page: 1,
          pageSize: 10,
          storageId: 'st1',
          parentPath: 'V',
          nodeKind: MediaNodeKind.file,
          mediaTypes: const [MediaType.video, MediaType.audio],
        ),
      );

      expect(result.totalItems, 2);
      expect(
        result.items.map((e) => e.name),
        containsAll(['v.mp4', 'a.mp3']),
      );
    });
  });

  group('Temporary resolution overrides (preview local sort)', () {
    late AppDatabase db;
    late ScenarioRepository repo;
    late ScenarioResolver resolver;

    setUp(() async {
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
        // Store-free env: pin the legacy playable-only semantics instead of
        // the browse-scope funnel (which needs an initialized AppStore).
        scopedMediaTypes: () => null,
      );
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> seedMedia(List<(String storageId, String path)> files) async {
      final dao = MediaNodesDao(db);
      for (final (storageId, path) in files) {
        await dao.insertNode(
          MediaNode.file(
            id: path,
            storageId: storageId,
            path: path.split('/'),
            name: path.split('/').last,
            mediaType: MediaType.video,
          ),
        );
      }
    }

    test(
        'resolvePage sort overrides change the resolved order without writing '
        'the scenario', () async {
      await seedMedia([
        ('st1', 'A/ccc.mp4'),
        ('st1', 'A/aaa.mp4'),
        ('st1', 'A/bbb.mp4'),
      ]);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id, storageId: 'st1', path: 'A', recursive: true);

      // Persisted default: name asc.
      final base = await resolver.resolvePage(
          scenarioId: scenario.id, page: 0, pageSize: 10);
      expect(base.items.map((e) => e.media.name).toList(),
          ['aaa.mp4', 'bbb.mp4', 'ccc.mp4']);

      // Temporary local override: name desc.
      final desc = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.desc,
      );
      expect(desc.items.map((e) => e.media.name).toList(),
          ['ccc.mp4', 'bbb.mp4', 'aaa.mp4']);

      // Nothing persisted: the scenario Definition is untouched.
      final persisted = await repo.getScenario(scenario.id);
      expect(persisted!.sortField, ScenarioSortField.name);
      expect(persisted.sortDirection, SortDirection.asc);
    });

    test(
        'sourceInternalFirst override groups or flattens locally without '
        'writing the scenario', () async {
      await seedMedia([
        ('st1', 'B/a.mp4'),
        ('st1', 'A/c.mp4'),
        ('st1', 'A/b.mp4'),
      ]);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id, storageId: 'st1', path: '', recursive: true);

      // ON: same-parent files contiguous → A/b, A/c, then B/a.
      final grouped = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
        sourceInternalFirst: true,
      );
      expect(grouped.items.map((e) => e.media.name).toList(),
          ['b.mp4', 'c.mp4', 'a.mp4']);

      // OFF: single global field sort → a, b, c.
      final flat = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
        sourceInternalFirst: false,
      );
      expect(flat.items.map((e) => e.media.name).toList(),
          ['a.mp4', 'b.mp4', 'c.mp4']);

      final persisted = await repo.getScenario(scenario.id);
      // The override never writes the scenario, whose default is now false.
      expect(persisted!.sourceInternalFirst, isFalse);
    });

    test(
        'order + shuffleSeed overrides enable a LOCAL shuffle; asc and desc '
        'are mutual reverses', () async {
      await seedMedia([
        for (var i = 1; i <= 5; i++)
          ('st1', 'A/ep${i.toString().padLeft(2, '0')}.mp4'),
      ]);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id, storageId: 'st1', path: 'A', recursive: true);

      final names = ['ep01.mp4', 'ep02.mp4', 'ep03.mp4', 'ep04.mp4', 'ep05.mp4'];
      final asc = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
        order: PlaybackOrder.shuffled,
        shuffleSeed: 42,
        sortDirection: SortDirection.asc,
      );
      final desc = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
        order: PlaybackOrder.shuffled,
        shuffleSeed: 42,
        sortDirection: SortDirection.desc,
      );

      // Both are permutations of the same media…
      expect(asc.items.map((e) => e.media.name).toSet(), names.toSet());
      expect(desc.items.map((e) => e.media.name).toSet(), names.toSet());
      // …desc is the exact reversal of asc…
      expect(asc.items.map((e) => e.media.name).toList(),
          desc.items.map((e) => e.media.name).toList().reversed.toList());
      // …and the shuffle is actually applied (not the sequential order).
      expect(asc.items.map((e) => e.media.name).toList(),
          isNot(orderedEquals(names)));
    });

    test('order override WITHOUT a seed does not shuffle (no seed to use)',
        () async {
      await seedMedia([
        for (var i = 1; i <= 5; i++)
          ('st1', 'A/ep${i.toString().padLeft(2, '0')}.mp4'),
      ]);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id, storageId: 'st1', path: 'A', recursive: true);

      // state has no shuffle seed and no override seed → shuffled stays false.
      final page = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
        order: PlaybackOrder.shuffled,
      );
      expect(
          page.items.map((e) => e.media.name).toList(),
          ['ep01.mp4', 'ep02.mp4', 'ep03.mp4', 'ep04.mp4', 'ep05.mp4']);
    });

    test(
        'duplicatePolicy override dedups locally without writing the scenario',
        () async {
      await seedMedia([
        ('st1', 'videos/ep01.mp4'),
      ]);
      final scenario = await repo.createScenario(name: 'Dup');
      await repo.addSource(
          scenarioId: scenario.id, storageId: 'st1', path: 'videos', recursive: true);
      await repo.addSource(
          scenarioId: scenario.id, storageId: 'st1', path: '', recursive: true);

      final allow = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
        duplicatePolicy: DuplicatePolicy.allowDuplicate,
      );
      expect(allow.items.length, 2);
      expect(allow.items.first.duplicated, isFalse);
      expect(allow.items.last.duplicated, isTrue);

      final dedup = await resolver.resolvePage(
        scenarioId: scenario.id,
        page: 0,
        pageSize: 10,
        duplicatePolicy: DuplicatePolicy.deduplicate,
      );
      expect(dedup.items.length, 1);
      expect(dedup.items.first.media.name, 'ep01.mp4');

      final persisted = await repo.getScenario(scenario.id);
      expect(persisted!.duplicatePolicy, DuplicatePolicy.allowDuplicate);
    });
  });

  group('ScenarioPlaybackProvider list-independence', () {
    late AppDatabase db;
    late PlaybackScenarioStore store;
    late ScenarioPlaybackProvider provider;

    setUpAll(() {
      db = AppDatabase(NativeDatabase.memory());
      DbModule.init(db);
    });

    tearDownAll(() async {
      await db.close();
    });

    setUp(() async {
      // Shared in-memory DB → clear persisted rows so each test starts clean.
      await db.customStatement('DELETE FROM media_nodes');
      await db.customStatement('DELETE FROM scenario');
      await db.customStatement('DELETE FROM scenario_sources');
      await db.customStatement('DELETE FROM scenario_explicit_items');
      await db.customStatement('DELETE FROM scenario_excludes');
      await db.customStatement('DELETE FROM scenario_state');
      // The derived representations must go too. A leftover shared ORDER is
      // keyed by (storage, sort, types) and stamped with the media revision the
      // test never bumps, so the next test would reuse an order built for the
      // PREVIOUS test's file set — the gate would refuse it (correctly) and the
      // read would silently degrade to the legacy walk.
      await db.customStatement('DELETE FROM scenario_queue_builds');
      await db.customStatement('DELETE FROM scenario_shared_index');
      await db.customStatement('DELETE FROM media_orders');
      // The bar position is process-wide (see PlaybackPositionSignal), so each
      // test must start from "nothing located" or it would inherit the previous
      // case's index.
      PlaybackPositionSignal.instance.clear();
      store = PlaybackScenarioStore();
      await store.initialized;
      provider = ScenarioPlaybackProvider(store: store);
    });

    tearDown(() async {
      await store.dispose();
      PlaybackPositionSignal.instance.clear();
    });

    Future<void> seedMedia(List<(String storageId, String path)> files) async {
      final dao = MediaNodesDao(db);
      for (final (storageId, path) in files) {
        await dao.insertNode(
          MediaNode.file(
            id: path,
            storageId: storageId,
            path: path.split('/'),
            name: path.split('/').last,
            mediaType: MediaType.video,
          ),
        );
      }
    }

    Future<String> newScenario() async {
      final s = await DbModule.scenarioRepo.createScenario(name: 'S');
      await store.setActiveScenario(s.id);
      return s.id;
    }

    test('folder-play override clears stale explicit items (E1)', () async {
      final sys = await store.ensureSystemPlayingScenario();
      await store.setActiveScenario(sys.id);

      // Stale explicit item from a previous append/selection must NOT survive
      // a folder override (_replaceSources behaviour).
      await store.addExplicitItemFor(
        scenarioId: sys.id,
        storageId: 'st1',
        path: 'stale/ep.mp4',
      );
      await store.addSource(storageId: 'st1', path: 'old', recursive: true);

      await store.clearSources(sys.id);
      await store.clearExplicitItems(sys.id);
      await store.clearTemporaryExcludes(sys.id);
      await store.addSource(storageId: 'st1', path: 'newdir', recursive: true);

      expect(await store.getExplicitItems(sys.id), isEmpty);
      final sources = await store.getSources(sys.id);
      expect(sources.map((s) => s.path), ['newdir']);
    });

    test('itemAt reaches items past the legacy 10000 locate bound', () async {
      // Bulk-seed 10001 files (CTE) so the queue has a row past the old
      // `_maxLocateItems` prefix-scan bound; the index seek must reach it.
      await db.customStatement(
        'INSERT INTO media_nodes '
        '(id, storage_id, data_scope_id, path, name, node_kind, media_type, path_depth) '
        'WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM seq WHERE i < 10000) '
        "SELECT i + 1, 'st1', 'st1', 'A/' || printf('%05d', i) || '.mp4', "
        "printf('%05d', i) || '.mp4', 'file', 'video', 2 FROM seq",
      );
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);
      // Build the persisted index so the O(log n) seek path is available.
      await store.resolvePage(page: 0, pageSize: 10);

      final entry = await provider.itemAt(10000);
      expect(entry, isNotNull,
          reason: 'items past the legacy 10000 bound must be reachable');
      expect(entry!.path, 'A/10000.mp4');
    });

    test('next follows the CURRENT order after a re-sort', () async {
      await seedMedia([
        ('st1', 'A/ep01.mp4'),
        ('st1', 'A/ep02.mp4'),
        ('st1', 'A/ep03.mp4'),
      ]);
      final dao = MediaNodesDao(db);
      await dao.updateFileDuration('st1', 'A/ep01.mp4', 3000);
      await dao.updateFileDuration('st1', 'A/ep02.mp4', 1000);
      await dao.updateFileDuration('st1', 'A/ep03.mp4', 2000);

      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);

      // Current = ep03 (last in name-asc order) → next is null.
      await store.setCurrentItem(
        occurrence:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep03.mp4'),
        virtualPos: 2,
      );
      expect((await provider.next())?.path, isNull);

      // durationMs asc → [ep02, ep03, ep01]; ep03 now has a next.
      await store.setSort(ScenarioSortField.durationMs, SortDirection.asc);
      expect((await provider.next())?.path, 'A/ep01.mp4');
    });

    test('next follows the CURRENT order after toggling 同目录连续 (sourceInternalFirst)',
        () async {
      // Order depends ONLY on the 同目录连续 flag, which the locate-cache
      // fingerprint previously ignored → next() served a stale index (the
      // reported "4th video → PageDown lands on the 12th" class of bug).
      await seedMedia([
        ('st1', 'A/a.mp4'),
        ('st1', 'A/b.mp4'),
        ('st1', 'B/a.mp4'),
        ('st1', 'B/b.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: '', recursive: true);

      // 同目录连续 ON → A/a, A/b, B/a, B/b. Current = A/b.
      await store.setSourceInternalFirst(true);
      await store.setCurrentItem(
        occurrence: const PlaybackOccurrenceId(storageId: 'st1', path: 'A/b.mp4'),
        virtualPos: 1,
      );
      // Prime the locate cache with the ON-order index of A/b via a round trip.
      expect((await provider.next())?.path, 'B/a.mp4');
      expect((await provider.previous())?.path, 'A/b.mp4');

      // Toggle OFF → global name asc: A/a, B/a, A/b, B/b; A/b is now index 2,
      // so the item AFTER it is B/b. A stale cache (index 1) would serve B/a.
      await store.setSourceInternalFirst(false);
      expect((await provider.next())?.path, 'B/b.mp4');
    });

    test('sourceInternalFirst change survives a fresh-provider tap (stale singleton cache)',
        () async {
      await seedMedia([
        ('st1', 'A/a.mp4'),
        ('st1', 'A/b.mp4'),
        ('st1', 'B/a.mp4'),
        ('st1', 'B/b.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: '', recursive: true);
      await store.setCurrentItem(
        occurrence: const PlaybackOccurrenceId(storageId: 'st1', path: 'A/b.mp4'),
        virtualPos: 1,
      );
      // 同目录连续 ON first, so the long-lived cache is primed grouped.
      await store.setSourceInternalFirst(true);
      // Prime the long-lived provider's cache under the ON order, then toggle.
      expect((await provider.next())?.path, 'B/a.mp4');
      expect((await provider.previous())?.path, 'A/b.mp4');
      await store.setSourceInternalFirst(false);

      // A list tap runs through a short-lived provider (as playResolvedItem
      // does) — it must not resurrect the long-lived provider's stale index.
      final tapProvider = ScenarioPlaybackProvider(store: store);
      final tapped = await tapProvider.itemAt(2); // A/b in the OFF order
      await tapProvider.play(tapped!);
      expect((await provider.next())?.path, 'B/b.mp4');
    });

    // The bar title subscribes to ONE signal, but playback is initiated by two
    // different provider instances: a list tap builds a short-lived one, while
    // next/previous go through the registry singleton. When the notifier lived
    // on the instance, a tap published into an object that was discarded right
    // after — the title kept the pre-tap index until the first PageDown/PageUp
    // re-located it through the singleton.
    test('a fresh-provider tap publishes the bar position to every instance',
        () async {
      await seedMedia([
        ('st1', 'A/ep01.mp4'),
        ('st1', 'A/ep02.mp4'),
        ('st1', 'A/ep03.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);

      // Pre-tap state: the queue is located on the FIRST item, as a startup
      // resume would leave it.
      await store.setCurrentItem(
        occurrence:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep01.mp4'),
      );
      expect(await provider.establishCurrentPosition(), 0);
      expect(provider.position.value, (index: 0, count: 3));

      // Tap ep03 — NOT the first item — through a short-lived provider.
      final tapProvider = ScenarioPlaybackProvider(store: store);
      await tapProvider.play((await tapProvider.itemAt(2))!);

      // The pre-existing instance (the one the title listens to) must see it.
      expect(provider.position.value, (index: 2, count: 3));
    });

    test('a fresh-provider tap re-locates instead of keeping the stale index',
        () async {
      await seedMedia([
        ('st1', 'A/ep01.mp4'),
        ('st1', 'A/ep02.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);
      await store.setCurrentItem(
        occurrence:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep01.mp4'),
      );
      expect(await provider.establishCurrentPosition(), 0);
      expect(provider.position.value, (index: 0, count: 2));

      final tapProvider = ScenarioPlaybackProvider(store: store);
      await tapProvider.play((await tapProvider.itemAt(1))!);
      expect(provider.position.value, (index: 1, count: 2));
    });

    test('next resolves the current OCCURRENCE under duplicates', () async {
      await seedMedia([
        ('st1', 'A/x.mp4'),
        ('st1', 'A/k.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.updateScenario(
        (await DbModule.scenarioRepo.getScenario(id))!
            .copyWith(duplicatePolicy: DuplicatePolicy.allowDuplicate),
      );
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: '', recursive: true);

      // Effective order (name asc per segment): [k0, x0, k1, x1].
      // k1 (index 2) is followed by x1 (the second occurrence of x).
      await store.setCurrentItem(
        occurrence: const PlaybackOccurrenceId(
            storageId: 'st1', path: 'A/k.mp4', occurrenceIndex: 1),
        virtualPos: 2,
      );
      final next1 = await provider.next();
      expect(next1?.path, 'A/x.mp4');
      expect(next1?.occurrenceIndex, 1);

      // x1 (index 3, last) → next is null. Without the occurrence-aware
      // locate, x1 would be mistaken for x0 (index 1) → next would be k1.
      await store.setCurrentItem(
        occurrence: const PlaybackOccurrenceId(
            storageId: 'st1', path: 'A/x.mp4', occurrenceIndex: 1),
        virtualPos: 3,
      );
      expect((await provider.next())?.path, isNull);
    });

    test('wrapToFirst persists index 0 so the loop advances (Repeat.all)',
        () async {
      await seedMedia([
        ('st1', 'A/ep01.mp4'),
        ('st1', 'A/ep02.mp4'),
        ('st1', 'A/ep03.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);

      // Current = ep03 (last in name-asc order) → next is null at the end.
      await store.setCurrentItem(
        occurrence:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep03.mp4'),
        virtualPos: 2,
      );
      expect((await provider.next())?.path, isNull);

      // Loop back to the first item; the ordering hint must move to index 0.
      final wrapped = await provider.wrapToFirst();
      expect(wrapped?.path, 'A/ep01.mp4');
      expect((await store.getState(id))?.currentVirtualPos, 0);

      // The completion that follows must ADVANCE to ep02, not re-wrap.
      expect((await provider.next())?.path, 'A/ep02.mp4');
    });

    test('wrapToLast persists the last index so previous loops (Repeat.all)',
        () async {
      await seedMedia([
        ('st1', 'A/ep01.mp4'),
        ('st1', 'A/ep02.mp4'),
        ('st1', 'A/ep03.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);

      // Current = ep01 (head) → previous is null at the head.
      await store.setCurrentItem(
        occurrence:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep01.mp4'),
        virtualPos: 0,
      );
      expect((await provider.previous())?.path, isNull);

      // Loop back to the last item; the ordering hint must move to the tail.
      final wrapped = await provider.wrapToLast();
      expect(wrapped?.path, 'A/ep03.mp4');
      expect((await store.getState(id))?.currentVirtualPos, 2);

      // The previous that follows must go BACK to ep02, not re-wrap.
      expect((await provider.previous())?.path, 'A/ep02.mp4');
    });

    test('stop resets progress to 0 and keeps the current item', () async {
      await seedMedia([
        ('st1', 'A/ep01.mp4'),
        ('st1', 'A/ep02.mp4'),
        ('st1', 'A/ep03.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);

      // Current = ep02 (middle) with a resume position primed.
      await store.setCurrentItem(
        occurrence:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep02.mp4'),
        virtualPos: 1,
      );
      final ep02 = (await provider.current())!;
      await persistPlaybackProgress(
        file: ep02.file,
        position: const Duration(minutes: 3),
        completed: false,
      );
      expect(await readPlaybackProgress(ep02.file), 3 * 60 * 1000);
      expect(await readPlaybackCompleted(ep02.file), isFalse);

      // The file HAS been opened before (parsed duration present) — stop is a
      // legitimate PotPlayer-style reset target.
      await MediaNodesDao(db)
          .updateFileDuration('st1', 'A/ep02.mp4', 180000);

      // Stop: progress reset to 0 + completed, current item unchanged.
      await provider.stop();
      expect(await readPlaybackProgress(ep02.file), 0);
      expect(await readPlaybackCompleted(ep02.file), isTrue);

      final current = await provider.current();
      expect(current?.key, ep02.key);
      expect(current?.occurrenceIndex, ep02.occurrenceIndex);

      // Playback continuity from the stopped item still works.
      expect((await provider.next())?.path, 'A/ep03.mp4');
    });

    test('stop on a never-opened file does not flag it completed', () async {
      // A stop that follows a FAILED open must not mark the media watched:
      // without a parsed duration the row was never successfully played.
      await seedMedia([
        ('st1', 'A/ep01.mp4'),
        ('st1', 'A/ep02.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);

      await store.setCurrentItem(
        occurrence:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep02.mp4'),
        virtualPos: 1,
      );
      final ep02 = (await provider.current())!;

      await provider.stop();
      expect(await readPlaybackProgress(ep02.file), isNull);
      expect(await readPlaybackCompleted(ep02.file), isFalse);
    });

    test('itemAt stays exact across page boundaries under compaction',
        () async {
      // 105 files; the FIRST TWO are excluded → effective stream e003..e105
      // (103 items). Fixed-base windows restart at their nominal offsets, so a
      // windowed lookup for index 100 would return e101 (base slot) instead of
      // the TRUE 101st effective item, e103.
      await seedMedia([
        for (var i = 1; i <= 105; i++)
          ('st1', 'A/e${i.toString().padLeft(3, '0')}.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);
      await store.addExcludeRule(ScenarioExcludeRule(
        id: 0,
        scenarioId: id,
        kind: ExcludeRuleKind.media,
        storageId: 'st1',
        path: 'A/e001.mp4',
      ));
      await store.addExcludeRule(ScenarioExcludeRule(
        id: 0,
        scenarioId: id,
        kind: ExcludeRuleKind.media,
        storageId: 'st1',
        path: 'A/e002.mp4',
      ));

      expect((await provider.itemAt(0))?.path, 'A/e003.mp4');
      expect((await provider.itemAt(99))?.path, 'A/e102.mp4');
      expect((await provider.itemAt(100))?.path, 'A/e103.mp4');
      expect((await provider.itemAt(102))?.path, 'A/e105.mp4');
      expect(await provider.itemAt(103), isNull);
    });

    test('locate pins the true effective index under compaction', () async {
      await seedMedia([
        for (var i = 1; i <= 105; i++)
          ('st1', 'A/e${i.toString().padLeft(3, '0')}.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);
      await store.addExcludeRule(ScenarioExcludeRule(
        id: 0,
        scenarioId: id,
        kind: ExcludeRuleKind.media,
        storageId: 'st1',
        path: 'A/e001.mp4',
      ));
      await store.addExcludeRule(ScenarioExcludeRule(
        id: 0,
        scenarioId: id,
        kind: ExcludeRuleKind.media,
        storageId: 'st1',
        path: 'A/e002.mp4',
      ));

      // e104 sits at effective index 101 (base 103 − 2 excluded slots).
      await store.setCurrentItem(
        occurrence:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'A/e104.mp4'),
      );
      expect(await provider.establishCurrentPosition(), 101);
      expect((await store.getState(id))?.currentVirtualPos, 101);

      // Continuity from the compacted position: next is e105, not a duplicate
      // re-served by an overlapping page window.
      expect((await provider.next())?.path, 'A/e105.mp4');
    });

    test('applyQueueGenerationRule records original and exits shuffle',
        () async {
      final scenario = await DbModule.scenarioRepo.createScenario(name: 'Gen');
      await store.setActiveScenario(scenario.id);
      await store.toggleShuffle();
      await store.applyQueueGenerationRule(
        sortField: ScenarioSortField.sizeInBytes,
        sortDirection: SortDirection.desc,
      );

      final updated = await DbModule.scenarioRepo.getScenario(scenario.id);
      expect(updated!.sortField, ScenarioSortField.sizeInBytes);
      expect(updated.sortDirection, SortDirection.desc);
      expect(updated.originalSortField, ScenarioSortField.sizeInBytes);
      expect(updated.order, PlaybackOrder.sequential);
      expect(store.state.activeScenarioShuffled, isFalse);
    });

    test(
        'establishCurrentPosition pins a tapped non-first item so next/prev work',
        () async {
      await seedMedia([
        ('st1', 'A/ep01.mp4'),
        ('st1', 'A/ep02.mp4'),
        ('st1', 'A/ep03.mp4'),
        ('st1', 'A/ep04.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);

      // Tap ep02 — NOT the first item of the queue.
      await store.setCurrentItem(
        occurrence:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep02.mp4'),
      );
      final index = await provider.establishCurrentPosition();
      expect(index, 1);

      // The actual index (1) is persisted as the ordering hint.
      final state = await DbModule.scenarioRepo.getState(id);
      expect(state!.currentVirtualPos, 1);

      // previous → ep01 (the item BEFORE the tapped ep02, not the queue head),
      // then next → back to ep02.
      final prev = await provider.previous();
      expect(prev?.path, 'A/ep01.mp4');
      final next = await provider.next();
      expect(next?.path, 'A/ep02.mp4');
    });

    test('setCurrentItem mirrors the current occurrence key reactively',
        () async {
      final scenario =
          await DbModule.scenarioRepo.createScenario(name: 'Mirror');
      await store.setActiveScenario(scenario.id);
      expect(store.state.currentOccurrenceKey, isNull);

      await store.setCurrentItem(
        occurrence: const PlaybackOccurrenceId(
            storageId: 'st1', path: 'A/k.mp4', occurrenceIndex: 1),
      );
      expect(store.state.currentOccurrenceKey, 'st1:A/k.mp4#1');
    });

    test(
        'mirror matches the resolved occurrence after establishCurrentPosition',
        () async {
      await seedMedia([
        ('st1', 'A/ep01.mp4'),
        ('st1', 'A/ep02.mp4'),
        ('st1', 'A/ep03.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);

      await store.setCurrentItem(
        occurrence:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep02.mp4'),
      );
      await provider.establishCurrentPosition();

      // The mirror must equal the RESOLVED occurrence key (what queue items
      // carry), so the select-driven highlight matches exactly.
      final current = await provider.current();
      expect(store.state.currentOccurrenceKey,
          '${current!.key}#${current.occurrenceIndex}');
      expect(store.state.currentOccurrenceKey, 'st1:A/ep02.mp4#0');
    });

    test('setSort refreshes the scenario mirror (source of truth)', () async {
      final scenario = await DbModule.scenarioRepo.createScenario(name: 'S');
      await store.setActiveScenario(scenario.id);

      await store.setSort(ScenarioSortField.sizeInBytes, SortDirection.desc);

      final mirrored =
          store.state.scenarios.firstWhere((c) => c.id == scenario.id);
      expect(mirrored.sortField, ScenarioSortField.sizeInBytes);
      expect(mirrored.sortDirection, SortDirection.desc);
    });

    test('setSourceInternalFirst persists and refreshes the mirror', () async {
      final id = await newScenario();
      await store.refreshScenarios();

      // Default false (D6): flat order, so a plain field sort (e.g. by
      // modified date) reads as one global sequence, not folder blocks.
      expect((await store.getScenario(id))!.sourceInternalFirst, isFalse);
      expect(
        store.state.scenarios.firstWhere((c) => c.id == id).sourceInternalFirst,
        isFalse,
      );

      await store.setSourceInternalFirst(true);
      expect((await store.getScenario(id))!.sourceInternalFirst, isTrue);
      expect(
        store.state.scenarios.firstWhere((c) => c.id == id).sourceInternalFirst,
        isTrue,
      );

      await store.setSourceInternalFirst(false);
      expect((await store.getScenario(id))!.sourceInternalFirst, isFalse);
      expect(
        store.state.scenarios.firstWhere((c) => c.id == id).sourceInternalFirst,
        isFalse,
      );
    });

    test('toggleShuffleDirection flips direction while shuffled', () async {
      final id = await newScenario();
      await store.refreshScenarios();

      // No-op when not shuffled.
      await store.toggleShuffleDirection();
      expect((await store.getScenario(id))!.order, PlaybackOrder.sequential);

      // Enabling shuffle resets the direction to asc (forward).
      await store.toggleShuffle();
      expect((await store.getScenario(id))!.order, PlaybackOrder.shuffled);
      expect((await store.getScenario(id))!.sortDirection, SortDirection.asc);

      // Re-click flips to desc while staying shuffled; mirror follows.
      await store.toggleShuffleDirection();
      expect((await store.getScenario(id))!.sortDirection, SortDirection.desc);
      expect((await store.getScenario(id))!.order, PlaybackOrder.shuffled);
      final mirrored =
          store.state.scenarios.firstWhere((c) => c.id == id);
      expect(mirrored.sortDirection, SortDirection.desc);

      // And back to asc.
      await store.toggleShuffleDirection();
      expect((await store.getScenario(id))!.sortDirection, SortDirection.asc);
    });

    test('queue item and current item share the same live-progress key',
        () async {
      await seedMedia([
        ('st1', 'A/ep01.mp4'),
        ('st1', 'A/ep02.mp4'),
        ('st1', 'A/ep03.mp4'),
      ]);
      final id = await newScenario();
      await store.refreshScenarios();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);

      await store.setCurrentItem(
        occurrence:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep02.mp4'),
        virtualPos: 1,
      );
      final current = await store.getCurrentItem();
      expect(current, isNotNull);
      final cur = current!;

      // The queue page resolves the same media; find the matching item.
      final page = await store.resolvePageFor(id, page: 0, pageSize: 10);
      EffectivePlaybackItem? matched;
      for (final e in page.items) {
        if (e.mediaKey == cur.mediaKey) {
          matched = e;
          break;
        }
      }
      expect(matched, isNotNull);
      final matchedItem = matched!;

      // LiveProgressChip keys progress by canonicalProgressKey(media.storageId,
      // media.path); both the queue item and the currently playing item must
      // map to the same key so the live store value is found.
      // final currentKey = ScenarioPlaybackProvider().fileOf(cur.media).getID(); // legacy
      final currentKey = canonicalProgressKey(cur.media.storageId, cur.media.path); // unified
      // final queueKey = ScenarioPlaybackProvider().fileOf(matchedItem.media).getID(); // legacy
      final queueKey =
          canonicalProgressKey(matchedItem.media.storageId, matchedItem.media.path); // unified
      expect(queueKey, currentKey);
      // The store key is the canonical progress key shape.
      expect(currentKey, 'st1:A/ep02.mp4');
    });

    test('resolvePageFor forwards temporary sort overrides without persisting',
        () async {
      await seedMedia([
        ('st1', 'A/ccc.mp4'),
        ('st1', 'A/aaa.mp4'),
        ('st1', 'A/bbb.mp4'),
      ]);
      final id = await newScenario();
      await DbModule.scenarioRepo.addSource(
          scenarioId: id, storageId: 'st1', path: 'A', recursive: true);

      final asc = await store.resolvePageFor(
        id,
        page: 0,
        pageSize: 10,
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.asc,
      );
      final desc = await store.resolvePageFor(
        id,
        page: 0,
        pageSize: 10,
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.desc,
      );

      expect(asc.items.map((e) => e.media.name).toList(),
          ['aaa.mp4', 'bbb.mp4', 'ccc.mp4']);
      expect(desc.items.map((e) => e.media.name).toList(),
          ['ccc.mp4', 'bbb.mp4', 'aaa.mp4']);

      final persisted = await DbModule.scenarioRepo.getScenario(id);
      expect(persisted!.sortField, ScenarioSortField.name);
      expect(persisted.sortDirection, SortDirection.asc);
    });

    test('overrideWorkspace installs source config and syncs the mirror',
        () async {
      final sys = await store.ensureSystemPlayingScenario();
      final source = await DbModule.scenarioRepo.createScenario(name: 'Src');
      await DbModule.scenarioRepo.addSource(
          scenarioId: source.id, storageId: 'st1', path: 'A', recursive: true);
      await store.setActiveScenario(source.id);
      await store.setSort(ScenarioSortField.durationMs, SortDirection.desc);
      final updatedSource = await store.getScenario(source.id);

      await store.overrideWorkspace(workspace: sys, source: updatedSource);

      final ws = await store.getScenario(sys.id);
      expect(ws!.sortField, ScenarioSortField.durationMs);
      final mirrored = store.state.scenarios.firstWhere((c) => c.id == sys.id);
      expect(mirrored.sortField, ScenarioSortField.durationMs);
    });

    test('saveWorkspaceAs increments saveCounter; other actions do not (D2)',
        () async {
      final sys = await store.ensureSystemPlayingScenario();
      expect(store.state.saveCounter, 0);

      await store.saveWorkspaceAs(sys, name: 'Saved', description: 'd');
      expect(store.state.saveCounter, 1);
      // Next default name starts from counter+1.
      expect(store.nextDefaultScenarioName(), 'Scenario 2');

      final target = await DbModule.scenarioRepo.createScenario(name: 'T');
      await store.overrideOther(workspace: sys, targetScenarioId: target.id);
      await store.appendOther(workspace: sys, targetScenarioId: target.id);
      expect(store.state.saveCounter, 1,
          reason: 'override/append must not touch the counter');
    });

    test('nextDefaultScenarioName starts at counter+1 and skips occupied',
        () async {
      final sys = await store.ensureSystemPlayingScenario();
      await DbModule.scenarioRepo.createScenario(name: 'Scenario 1');
      await store.refreshScenarios();

      // counter=0 → start at 1, but 'Scenario 1' is taken → skip to 2.
      expect(store.nextDefaultScenarioName(), 'Scenario 2');

      // After one save-new the counter is 1 → next default is Scenario 2.
      await store.saveWorkspaceAs(sys, name: 'MyPlan');
      expect(store.nextDefaultScenarioName(), 'Scenario 2');
    });

    test('isWorkspaceEmpty reflects sources and explicit items (O1)', () async {
      final sys = await store.ensureSystemPlayingScenario();
      expect(await store.isWorkspaceEmpty(sys.id), isTrue);

      await DbModule.scenarioRepo.addSource(
          scenarioId: sys.id, storageId: 'st1', path: 'A', recursive: true);
      expect(await store.isWorkspaceEmpty(sys.id), isFalse);

      await DbModule.scenarioRepo.clearSources(sys.id);
      await DbModule.scenarioRepo.addExplicitItem(
        scenarioId: sys.id,
        storageId: 'st1',
        path: 'A/ep01.mp4',
      );
      expect(await store.isWorkspaceEmpty(sys.id), isFalse);
    });
  });

  group('Scenario save-dialog actions (D5-D7/D14/D17)', () {
    late AppDatabase db;
    late ScenarioRepository repo;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = ScenarioRepository(
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

    test('copySourcesDedup skips existing (storageId, path)', () async {
      final source = await repo.createScenario(name: 'Src');
      final target = await repo.createScenario(name: 'Tgt');
      // Target already owns the A source.
      await repo.addSource(
          scenarioId: target.id, storageId: 'st1', path: 'A', recursive: true);
      // Source: A(dup with target) + B(new).
      await repo.addSource(
          scenarioId: source.id, storageId: 'st1', path: 'A', recursive: true);
      await repo.addSource(
          scenarioId: source.id, storageId: 'st1', path: 'B', recursive: false);

      await repo.copySourcesDedup(
        sourceScenarioId: source.id,
        targetScenarioId: target.id,
      );

      final targetSources = await repo.getSources(target.id);
      // A kept from target (dedup), B added.
      expect(targetSources.map((s) => s.path).toSet(), {'A', 'B'});
      // New sources appended with continuing sortOrder.
      final orders = targetSources.map((s) => s.sortOrder).toList();
      final expectedOrders = [...orders]..sort();
      expect(orders, expectedOrders);
      expect(orders.toSet().length, orders.length);
    });

    test('copySourcesDedup treats same path with different recursive as one',
        () async {
      final source = await repo.createScenario(name: 'Src');
      final target = await repo.createScenario(name: 'Tgt');
      // The scenario_sources table UNIQUE(scenario_id, storage_id, path)
      // constraint (no recursive in the key) means only ONE source per path can
      // exist — recursive is a property of that single row.
      await repo.addSource(
          scenarioId: source.id, storageId: 'st1', path: 'A', recursive: true);
      await repo.addSource(
          scenarioId: target.id, storageId: 'st1', path: 'A', recursive: false);

      await repo.copySourcesDedup(
        sourceScenarioId: source.id,
        targetScenarioId: target.id,
      );

      final targetSources = await repo.getSources(target.id);
      expect(targetSources.length, 1, reason: 'A already exists on target');
      // The existing row keeps its own recursive value.
      expect(targetSources.single.recursive, isFalse);
    });

    test('overrideTarget replaces target definition + config + state (D5)',
        () async {
      final sys = await repo.ensureSystemPlayingScenario();
      final target = await repo.createScenario(name: 'Target');
      // Workspace content.
      await repo.addSource(
          scenarioId: sys.id, storageId: 'st1', path: 'A', recursive: true);
      await repo.updateScenario(
        (await repo.getScenario(sys.id))!.copyWith(
          sortField: ScenarioSortField.durationMs,
          sourceInternalFirst: false,
        ),
      );
      // Target has a different source + config + an origin marker.
      await repo.addSource(
          scenarioId: target.id, storageId: 'st2', path: 'B', recursive: false);
      await repo.updateScenario(
        (await repo.getScenario(target.id))!
            .copyWith(sortField: ScenarioSortField.sizeInBytes),
      );
      await repo.updateState(ScenarioState(
        scenarioId: target.id,
        originScenarioId: 'some-origin',
        importedAt: DateTime.now(),
        importVersion: 5,
      ));

      await ScenarioCommands.overrideTarget(
        workspace: (await repo.getScenario(sys.id))!,
        targetScenarioId: target.id,
        description: 'overridden desc',
        repo: repo,
      );

      final t = await repo.getScenario(target.id);
      expect(t!.sortField, ScenarioSortField.durationMs);
      expect(t.sourceInternalFirst, isFalse);
      expect(t.description, 'overridden desc');
      expect(t.version, 1);
      // Sources replaced wholesale.
      final sources = await repo.getSources(target.id);
      expect(sources.map((s) => s.path), ['A']);
      expect(sources.every((s) => s.storageId == 'st1'), isTrue);
      // Origin/imported markers cleared (like saveAs).
      final state = await repo.getState(target.id);
      expect(state!.originScenarioId, isNull);
      expect(state.importVersion, isNull);
    });

    test('appendTarget merges with dedup, keeps target config + state (D6)',
        () async {
      final sys = await repo.ensureSystemPlayingScenario();
      final target = await repo.createScenario(name: 'Target');
      // Workspace sources: A(dup with target) + B(new).
      await repo.addSource(
          scenarioId: sys.id, storageId: 'st1', path: 'A', recursive: true);
      await repo.addSource(
          scenarioId: sys.id, storageId: 'st1', path: 'B', recursive: false);
      // Target already has A + its own config + origin.
      await repo.addSource(
          scenarioId: target.id, storageId: 'st1', path: 'A', recursive: true);
      await repo.updateScenario(
        (await repo.getScenario(target.id))!
            .copyWith(sortField: ScenarioSortField.name),
      );
      await repo.updateState(ScenarioState(
        scenarioId: target.id,
        originScenarioId: 'keep-me',
      ));

      await ScenarioCommands.appendTarget(
        workspace: sys,
        targetScenarioId: target.id,
        description: 'appended desc',
        repo: repo,
      );

      final t = await repo.getScenario(target.id);
      expect(t!.sortField, ScenarioSortField.name, reason: 'config untouched');
      expect(t.description, 'appended desc');
      expect(t.version, 1);
      // A deduped (still 1), B appended.
      final sources = await repo.getSources(target.id);
      expect(sources.map((s) => s.path).toSet(), {'A', 'B'});
      // ScenarioState (incl. origin) untouched.
      final state = await repo.getState(target.id);
      expect(state!.originScenarioId, 'keep-me');
    });

    test('syncBack copies workspace state and clears origin markers', () async {
      final sys = await repo.ensureSystemPlayingScenario();
      final origin = await repo.createScenario(name: 'Origin');
      await repo.addSource(
          scenarioId: sys.id, storageId: 'st1', path: 'A', recursive: true);
      await repo.updateState(ScenarioState(
        scenarioId: sys.id,
        originScenarioId: origin.id,
        currentPlaybackOccurrence:
            const PlaybackOccurrenceId(storageId: 'st1', path: 'A/ep01.mp4'),
      ));

      final ok = await ScenarioCommands.syncBack(
        workspace: sys,
        repo: repo,
      );
      expect(ok, isTrue);

      final originState = await repo.getState(origin.id);
      expect(originState!.originScenarioId, isNull);
      expect(originState.currentPlaybackOccurrence!.path, 'A/ep01.mp4');
      final originSources = await repo.getSources(origin.id);
      expect(originSources.map((s) => s.path), ['A']);
      expect(
        (await repo.getScenario(origin.id))!.version,
        1,
      );
    });

    test('ScenarioCommands.override copies sourceInternalFirst (C4)', () async {
      final sys = await repo.ensureSystemPlayingScenario();
      final source = await repo.createScenario(name: 'Src');
      await repo.updateScenario(
        (await repo.getScenario(source.id))!
            .copyWith(sourceInternalFirst: false),
      );

      await ScenarioCommands.override(
        workspace: sys,
        source: (await repo.getScenario(source.id))!,
        repo: repo,
      );

      expect(
        (await repo.getScenario(sys.id))!.sourceInternalFirst,
        isFalse,
      );
    });
  });

  group('Source copy dedup & heal (legacy slash variants)', () {
    late AppDatabase db;
    late ScenarioRepository repo;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = ScenarioRepository(
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

    Future<Scenario> createScenario(String name) async =>
        repo.createScenario(name: name);

    /// Inserts a source row with a RAW caller-supplied path, bypassing the
    /// adapter's [canonicalDbPath] normalization — simulating legacy data
    /// whose slash convention differs from the write path.
    Future<void> insertRawSource(
        String scenarioId, String storageId, String path,
        {bool recursive = false}) async {
      await db.customStatement(
        'INSERT INTO scenario_sources '
        '(scenario_id, storage_id, path, recursive) VALUES (?, ?, ?, ?)',
        [scenarioId, storageId, path, recursive ? 1 : 0],
      );
    }

    test(
        'copySources dedups raw slash variants (A vs /A) without crashing',
        () async {
      final src = await createScenario('src');
      await insertRawSource(src.id, 'st1', 'A');
      await insertRawSource(src.id, 'st1', '/A');
      final tgt = await createScenario('tgt');

      await repo.copySources(sourceScenarioId: src.id, targetScenarioId: tgt.id);

      final copied = await repo.getSources(tgt.id);
      expect(copied, hasLength(1));
      expect(copied.single.path, 'A');
    });

    test('copySourcesDedup collapses raw slash variants against the target',
        () async {
      final src = await createScenario('src');
      await insertRawSource(src.id, 'st1', 'A');
      await insertRawSource(src.id, 'st1', '/A');
      final tgt = await createScenario('tgt');
      await insertRawSource(tgt.id, 'st1', 'A');

      await repo.copySourcesDedup(
          sourceScenarioId: src.id, targetScenarioId: tgt.id);

      expect(await repo.getSources(tgt.id), hasLength(1));
    });

    test('dedupeSources heals raw slash-variant duplicates keeping lowest id',
        () async {
      final src = await createScenario('src');
      await insertRawSource(src.id, 'st1', 'A');
      await insertRawSource(src.id, 'st1', '/A');
      await insertRawSource(src.id, 'st2', 'B');

      await repo.dedupeSources();

      final sources = await repo.getSources(src.id);
      expect(sources, hasLength(2));
      expect(sources.map((s) => s.path), containsAll(['A', 'B']));
    });

    test('dedupeSources widens the survivor when a duplicate was recursive',
        () async {
      final src = await createScenario('src');
      // Oldest row is the non-recursive one; the recursive copy was written
      // later. Healing must keep the WIDE scope, not silently narrow it.
      await insertRawSource(src.id, 'st1', 'A');
      await insertRawSource(src.id, 'st1', '/A', recursive: true);

      await repo.dedupeSources();

      final sources = await repo.getSources(src.id);
      expect(sources, hasLength(1));
      expect(sources.single.recursive, isTrue);
    });
  });
}
