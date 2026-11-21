import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/db/dao/media_order_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_shared_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_state.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_source_provider.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/path_conv.dart';

/// The queue's ONE index space: the ELEMENT's DISPLAY position.
///
/// An ordinary file is one element; a Virtual Merge group is ONE element (its
/// members never take part on their own), and `virtualIndex` is that element's
/// 0-based position in the list the user reads — the leading column renders
/// `virtualIndex + 1`, `rowInCurrentPage` matches on it, and the paging window
/// `[page*pageSize, (page+1)*pageSize)` covers it.
///
/// These tests pin that contract for the SHUFFLED view, where the previous
/// implementation labelled rows with their base rank instead: the numbers came
/// out as the permutation (6,1,4,2,7,11,…), the locate scrolled to the wrong
/// page, and a merged group's members (which shuffle scatters) stopped agreeing
/// with the group the tap path plays.
void main() {
  group('scenario shuffle display axis', () {
    late AppDatabase db;
    late ScenarioRepository repo;
    late ScenarioQueueIndexDao indexDao;
    late MediaOrderDao orderDao;
    late ScenarioSharedIndexDao sharedDao;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = ScenarioRepository(
        scenariosDao: ScenariosDao(db),
        sourcesDao: ScenarioSourcesDao(db),
        itemsDao: ScenarioExplicitItemsDao(db),
        excludesDao: ScenarioExcludesDao(db),
        statesDao: ScenarioStatesDao(db),
      );
      indexDao = ScenarioQueueIndexDao(db);
      orderDao = MediaOrderDao(db);
      sharedDao = ScenarioSharedIndexDao(db);
    });

    tearDown(() async {
      await db.close();
    });

    VirtualMediaRule mergeRule({
      int maxItemCount = 3,
      VmSortField sortField = VmSortField.fileName,
      SortDirection sortDir = SortDirection.asc,
    }) =>
        VirtualMediaRule(
          id: 'r1',
          name: 'R',
          matchMode: VmMatchMode.specifiedDirRecursive,
          paths: const ['A'],
          boundary: VmBoundaryMode.sameDirOnly,
          sortField: sortField,
          sortDir: sortDir,
          useDurationCap: false,
          useCountCap: true,
          maxItemCount: maxItemCount,
          titleTags: const [VmTitleTag.dirName, VmTitleTag.seq],
          enabled: true,
        );

    Future<void> seedMedia(int n,
        {String dir = 'A', List<int>? durations}) async {
      final dao = MediaNodesDao(db);
      for (var i = 0; i < n; i++) {
        final name = '${i.toString().padLeft(4, '0')}.mp4';
        final path = '$dir/$name';
        await dao.insertNode(
          MediaNode.file(
            id: path,
            storageId: 'st1',
            path: path.split('/'),
            name: name,
            mediaType: MediaType.video,
            durationMs: durations == null ? 60000 : durations[i],
          ),
        );
      }
    }

    ScenarioResolver buildResolver({List<VirtualMediaRule>? rules}) =>
        ScenarioResolver(
          repo: repo,
          nodeRepo: MediaNodeRepository(MediaNodesDao(db)),
          scopedMediaTypes: () => null,
          providers: {
            ScenarioSourceKind.folder:
                FolderSourceProvider(scopedMediaTypes: () => null),
          },
          vmRulesProvider: () async => rules ?? const [],
          queueIndexDao: indexDao,
          mediaOrderDao: orderDao,
          sharedIndexDao: sharedDao,
          mediaRevisionProvider: (_) async => 0,
        );

    Future<String> scenarioWithSource({
      PlaybackOrder order = PlaybackOrder.sequential,
      int? seed,
    }) async {
      final scenario = await repo.createScenario(name: 'Anime');
      await repo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'A',
        recursive: true,
      );
      if (order != PlaybackOrder.sequential) {
        await repo.updateScenario(
          (await repo.getScenario(scenario.id))!.copyWith(order: order),
        );
      }
      if (seed != null) {
        await repo.updateState(
          ScenarioState(scenarioId: scenario.id, shuffleSeed: seed),
        );
      }
      return scenario.id;
    }

    /// Sweeps every page and returns `(globalPosition, item.virtualIndex)`.
    Future<List<({int position, int virtualIndex})>> sweep(
      ScenarioResolver resolver,
      String id, {
      required int pageSize,
    }) async {
      final out = <({int position, int virtualIndex})>[];
      final probe = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: pageSize);
      final pages = (probe.totalItems / pageSize).ceil();
      for (var p = 0; p < pages; p++) {
        final page = await resolver.resolvePageIndexed(
            scenarioId: id, page: p, pageSize: pageSize);
        for (var i = 0; i < page.items.length; i++) {
          out.add((
            position: p * pageSize + i,
            virtualIndex: page.items[i].virtualIndex,
          ));
        }
      }
      return out;
    }

    test('a shuffled page numbers rows by DISPLAY position, not base rank',
        () async {
      await seedMedia(40);
      final resolver = buildResolver();
      final id = await scenarioWithSource(
          order: PlaybackOrder.shuffled, seed: 9);
      await resolver.buildQueueIndex(id);

      const pageSize = 7;
      final rows = await sweep(resolver, id, pageSize: pageSize);
      expect(rows, hasLength(40));
      for (final row in rows) {
        expect(
          row.virtualIndex,
          row.position,
          reason: 'row at display position ${row.position} must carry that '
              'position — the leading column renders virtualIndex + 1',
        );
      }

      // The permutation itself must still be in effect (the ORDER is shuffled,
      // only the labels change).
      final page0 = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 40);
      final natural = [
        for (var i = 0; i < 40; i++)
          canonicalKey('st1', 'A/${i.toString().padLeft(4, '0')}.mp4')
      ];
      expect(page0.items.map((e) => e.mediaKey).toList(), isNot(natural));
      expect(page0.items.map((e) => e.mediaKey).toSet(), natural.toSet());
    });

    test('totalItems under shuffle counts elements, so pages do not run past '
        'the end', () async {
      await seedMedia(10);
      final resolver = buildResolver();
      final id = await scenarioWithSource(
          order: PlaybackOrder.shuffled, seed: 5);
      await repo.addExcludeRule(
        scenarioId: id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: id,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'A/0003.mp4',
        ),
      );
      await resolver.buildQueueIndex(id);

      final page = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 20);
      expect(page.totalItems, 9, reason: 'the excluded file is not an element');
      expect(page.items, hasLength(9));

      // The last page must not be padded with a phantom row.
      final last = await resolver.resolvePageIndexed(
          scenarioId: id, page: 1, pageSize: 5);
      expect(last.items, hasLength(4));
      expect(
        (await sweep(resolver, id, pageSize: 5)).map((r) => r.virtualIndex),
        [for (var i = 0; i < 9; i++) i],
      );
    });

    test('resolveItemAtIndex answers with the DISPLAY position it was asked '
        'for', () async {
      await seedMedia(25);
      final resolver = buildResolver();
      final id = await scenarioWithSource(
          order: PlaybackOrder.shuffled, seed: 3);
      await resolver.buildQueueIndex(id);

      for (final s in [0, 1, 7, 24]) {
        final item = await resolver.resolveItemAtIndex(id, s);
        expect(item, isNotNull, reason: 'ordinal $s');
        expect(item!.virtualIndex, s, reason: 'ordinal $s');
      }
      expect(await resolver.resolveItemAtIndex(id, 25), isNull);
    });

    test('a shuffled merged group keeps its members and their order',
        () async {
      await seedMedia(12);
      final rules = [mergeRule(maxItemCount: 3)];
      final resolver = buildResolver(rules: rules);
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      Future<List<List<String>>> mergedRows(PlaybackOrder order,
          {int? seed}) async {
        if (order != PlaybackOrder.sequential) {
          await repo.updateScenario(
            (await repo.getScenario(id))!.copyWith(order: order),
          );
        }
        if (seed != null) {
          await repo.updateState(
            ScenarioState(scenarioId: id, shuffleSeed: seed),
          );
        }
        final page = await resolver.resolvePageIndexed(
            scenarioId: id, page: 0, pageSize: 50);
        return [
          for (final item in page.items.where((e) => e.virtualMerged))
            [for (final c in item.vmChildren) c.mediaKey],
        ];
      }

      final base = await mergedRows(PlaybackOrder.sequential);
      final shuffled = await mergedRows(PlaybackOrder.shuffled, seed: 11);
      expect(base, hasLength(4), reason: '12 files, 3 at a time');
      expect(shuffled, hasLength(4));

      String canon(List<String> keys) => (keys.toList()..sort()).join('|');
      expect(
        shuffled.map(canon).toSet(),
        base.map(canon).toSet(),
        reason: 'shuffle must not change WHICH files a group merges',
      );
      for (final row in shuffled) {
        final match = base.firstWhere((r) => canon(r) == canon(row));
        expect(
          row,
          match,
          reason: 'shuffle must not reorder a group\'s own segments '
              '(the group is exempt from the external order)',
        );
      }

      // …while the ROW ORDER really does follow the shuffle.
      final names = [
        for (final p in (await resolver.resolvePageIndexed(
                scenarioId: id, page: 0, pageSize: 50))
            .items)
          p.media.name
      ];
      expect(names.toSet().length, 4);
    });

    test('the group the tap path resolves IS the group the shuffled list '
        'shows', () async {
      await seedMedia(9);
      final rules = [mergeRule(maxItemCount: 3)];
      final resolver = buildResolver(rules: rules);
      final id = await scenarioWithSource(
          order: PlaybackOrder.shuffled, seed: 21);
      await resolver.buildQueueIndex(id);

      // Playback side: groups derive from the scenario's OWN stream, which the
      // fix keeps in base order (a merged group is exempt from the shuffle).
      final stream = await resolver.collectEffectiveItems(scenarioId: id);
      final playback = resolveGroupsForStream(stream, rules).inOrder;

      final page = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);
      final shown = [
        for (final item in page.items.where((e) => e.virtualMerged))
          [for (final c in item.vmChildren) c.mediaKey],
      ];
      String canon(List<String> keys) => (keys.toList()..sort()).join('|');
      final shownSets = shown.map(canon).toSet();
      final playbackSets = {
        for (final g in playback)
          canon([for (final s in g.segments) s.mediaKey]),
      };
      expect(shownSets, playbackSets,
          reason: 'the shuffled row must show exactly the group the tap plays');
      expect(shownSets.length, playback.length,
          reason: 'one group == one row (no run-splitting duplicates)');

      // The un-merged rows are exactly the files no group claims.
      final grouped = {
        for (final g in playback) ...[for (final s in g.segments) s.mediaKey],
      };
      final singles = [
        for (final item in page.items.where((e) => !e.virtualMerged))
          item.mediaKey
      ];
      expect(singles.toSet().intersection(grouped), isEmpty,
          reason: 'a group\'s members must never show as their own rows');
      expect(singles, hasLength(stream.length - grouped.length));
    });

    test('the legacy walk and the indexed read agree under shuffle + merges',
        () async {
      await seedMedia(9);
      final rules = [mergeRule(maxItemCount: 3)];
      final resolver = buildResolver(rules: rules);
      final id = await scenarioWithSource(
          order: PlaybackOrder.shuffled, seed: 4);
      await resolver.buildQueueIndex(id);

      final indexed = await resolver.resolvePageIndexed(
          scenarioId: id, page: 0, pageSize: 50);
      final legacy =
          await resolver.resolvePage(scenarioId: id, page: 0, pageSize: 50);

      expect(legacy.totalItems, indexed.totalItems);
      expect(
        legacy.items.map((e) => e.media.name).toList(),
        indexed.items.map((e) => e.media.name).toList(),
        reason: 'the fallback walk must produce the same shuffled list',
      );
      expect(
        legacy.items.map((e) => e.virtualIndex).toList(),
        indexed.items.map((e) => e.virtualIndex).toList(),
      );
    });

    test('a group keeps its RULE-defined members when the stream interleaves '
        'them', () async {
      // The scenario streams by NAME while the rule groups by DURATION, so one
      // chunk's members are scattered across the stream (0,2,4 | 6,8,1 |
      // 3,5,7). Deriving groups from the stream's consecutive runs would have
      // merged 0-1-2 instead: the row the list showed and the group the tap
      // played would be two different sets of files, and the same rule would
      // surface as a different number of rows.
      final durations = [
        for (var i = 0; i < 9; i++) ((i * 5) % 9 + 1) * 60000,
      ];
      await seedMedia(9, durations: durations);
      final rules = [
        mergeRule(maxItemCount: 3, sortField: VmSortField.duration),
      ];
      final resolver = buildResolver(rules: rules);
      final id = await scenarioWithSource();
      await resolver.buildQueueIndex(id);

      String key(int i) =>
          canonicalKey('st1', 'A/${i.toString().padLeft(4, '0')}.mp4');
      final expected = [
        [key(0), key(2), key(4)],
        [key(6), key(8), key(1)],
        [key(3), key(5), key(7)],
      ];

      // Playback side (what a tap resolves).
      final stream = await resolver.collectEffectiveItems(scenarioId: id);
      final playback = resolveGroupsForStream(stream, rules).inOrder;
      expect(
        playback.map((g) => [for (final s in g.segments) s.mediaKey]).toList(),
        expected,
        reason: 'the rule pipeline owns membership and its internal order',
      );

      // Displayed side: ONE row per group, same members, same order — and the
      // interleaved members never appear as rows of their own.
      for (final read in [
        await resolver.resolvePageIndexed(scenarioId: id, page: 0, pageSize: 50),
        await resolver.resolvePage(scenarioId: id, page: 0, pageSize: 50),
      ]) {
        expect(read.totalItems, expected.length);
        expect(read.items, hasLength(expected.length));
        final shown = [
          for (final item in read.items.where((e) => e.virtualMerged))
            [for (final c in item.vmChildren) c.mediaKey],
        ];
        expect(shown, expected, reason: 'rows are elements 0..N');
        expect(
          read.items.map((e) => e.virtualIndex).toList(),
          [for (var i = 0; i < expected.length; i++) i],
        );
        final singles = [
          for (final item in read.items.where((e) => !e.virtualMerged))
            item.mediaKey
        ];
        expect(singles, isEmpty,
            reason: 'every file here belongs to a group, so no plain row may '
                'appear alongside the merged ones');
      }
    });
  });
}
