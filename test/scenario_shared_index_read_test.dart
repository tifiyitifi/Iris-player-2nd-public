import 'dart:typed_data';

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
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_state.dart';
import 'package:iris/features/scenario_playback/model/enum/duplicate_policy.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_source_provider.dart';
import 'package:iris/features/scenario_playback/resolver/shared_index_codec.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/models/db/app_database.dart';

/// The shared-index read harness: every index-backed read path is exercised
/// against itself and, where the two slot spaces coincide, against the legacy
/// walk.
///
/// It used to be three-way (`shared == v43 == legacy`) with the v43 rows as the
/// strict reference. The v43 rows are RETIRED, so the byte-level reference is now
/// the frozen goldens (`scenario_shared_index_golden_test.dart`) and what stays
/// here are the reference-free invariants plus the legacy comparison for the
/// shapes where the legacy walk's RAW slots equal the index's ACCEPTED ones (no
/// excludes / dedup / shuffle); elsewhere the walk keeps its raw slots and the
/// index its accepted ones, which is a documented, pre-existing difference.
void main() {
  group('shared index reads', () {
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

    Future<void> seedFiles(Iterable<String> paths) async {
      final dao = MediaNodesDao(db);
      for (final path in paths) {
        await dao.insertNode(MediaNode.file(
          id: path,
          storageId: 'st1',
          path: path.split('/'),
          name: path.split('/').last,
          mediaType: MediaType.video,
          durationMs: 60000,
        ));
      }
    }

    Future<void> seedA(int n) => seedFiles(
        [for (var i = 0; i < n; i++) 'A/${i.toString().padLeft(4, '0')}.mp4']);

    VirtualMediaRule mergeRule({int maxItemCount = 3, String? id}) =>
        VirtualMediaRule(
          id: id ?? 'r1',
          name: 'R',
          matchMode: VmMatchMode.specifiedDirRecursive,
          paths: const ['A'],
          boundary: VmBoundaryMode.sameDirOnly,
          useDurationCap: false,
          useCountCap: true,
          maxItemCount: maxItemCount,
          enabled: true,
        );

    ScenarioResolver buildResolver({
      required bool shared,
      List<VirtualMediaRule>? rules,
      Map<ScenarioSourceKind, ScenarioSourceProvider>? providers,
    }) =>
        ScenarioResolver(
          repo: repo,
          nodeRepo: MediaNodeRepository(MediaNodesDao(db)),
          scopedMediaTypes: () => null,
          providers: providers ??
              {
                ScenarioSourceKind.folder:
                    FolderSourceProvider(scopedMediaTypes: () => null),
              },
          vmRulesProvider: () async => rules ?? const [],
          queueIndexDao: indexDao,
          mediaOrderDao: orderDao,
          sharedIndexDao: sharedDao,
          mediaRevisionProvider: (_) async => 0,
          useSharedIndexRead: shared,
        );

    /// Folder + file, i.e. the two providers production registers by default.
    Map<ScenarioSourceKind, ScenarioSourceProvider> folderAndFile() => {
          ScenarioSourceKind.folder:
              FolderSourceProvider(scopedMediaTypes: () => null),
          ScenarioSourceKind.file: const FileSourceProvider(),
        };

    String key(EffectivePlaybackItem item) =>
        '${item.media.storageId}:${item.media.path.join('/')}'
        '#${item.occurrenceId.occurrenceIndex}';

    /// Exercises every shared-index-backed read path against ITSELF, plus the
    /// legacy walk where the two slot spaces are identical.
    ///
    /// `shared == v43` was the old reference; the v43 rows are retired and the
    /// frozen goldens (`scenario_shared_index_golden_test.dart`) now hold the
    /// exact expected reads. What is left here are the invariants that need no
    /// reference at all: one base slot per visible row across the sweep, the sweep
    /// and the ordinal seek covering exactly the same rows, and occurrence
    /// recovery answering for every row AND every file a merged row absorbed.
    Future<void> expectSharedReads({
      required String scenarioId,
      required bool expectLegacyParity,
      List<VirtualMediaRule>? rules,
      Map<ScenarioSourceKind, ScenarioSourceProvider>? providers,
      int pageSize = 7,
      PlaybackOrder? order,
      int? seed,
      SortDirection? sortDirection,
    }) async {
      final shared =
          buildResolver(shared: true, rules: rules, providers: providers);
      final legacy =
          buildResolver(shared: false, rules: rules, providers: providers);

      final probe = await shared.resolvePageIndexed(
          scenarioId: scenarioId, page: 0, pageSize: pageSize);
      final pages = (probe.totalItems / pageSize).ceil().clamp(1, 1000);
      final swept = <EffectivePlaybackItem>[];
      for (var page = 0; page < pages; page++) {
        final b = await shared.resolvePageIndexed(
            scenarioId: scenarioId,
            page: page,
            pageSize: pageSize,
            order: order,
            shuffleSeed: seed,
            sortDirection: sortDirection);
        expect(b.totalItems, probe.totalItems, reason: 'page $page totalItems');
        swept.addAll(b.items);

        if (expectLegacyParity) {
          final l = await legacy.resolvePage(
              scenarioId: scenarioId,
              page: page,
              pageSize: pageSize,
              order: order,
              shuffleSeed: seed,
              sortDirection: sortDirection);
          expect(b.items.map(key).toList(), l.items.map(key).toList(),
              reason: 'page $page vs legacy walk');
        }
      }

      // A group row absorbs its members' slots, so a slot is served by ONE row:
      // two rows on the same slot would mean the sweep double-counted a page
      // window (the "group spanning a page edge appears twice" bug).
      expect(swept.map((e) => e.virtualIndex).toSet().length, swept.length,
          reason: 'a base slot must be served at most once across the sweep');
      expect(swept.length, lessThanOrEqualTo(probe.totalItems));

      final buildId = await indexDao.currentBuildId(scenarioId);
      expect(await shared.indexedTotalCount(buildId), probe.totalItems,
          reason: 'indexedTotalCount');

      // The ordinal seek walks the same positions the sweep pages over (in sweep
      // order for a sequential queue, through the permutation for a shuffled
      // one), so both must cover exactly the same rows.
      final seekKeys = <String>[];
      for (var i = 0; i < probe.totalItems; i++) {
        final item = await shared.resolveItemAtIndex(
          scenarioId,
          i,
          order: order,
          shuffleSeed: seed,
          sortDirection: sortDirection,
        );
        if (item != null) seekKeys.add(key(item));
      }
      expect(seekKeys..sort(), swept.map(key).toList()..sort(),
          reason: 'the seek and the sweep must cover the same rows');
      expect(
        await shared.resolveItemAtIndex(scenarioId, probe.totalItems,
            order: order,
            shuffleSeed: seed,
            sortDirection: sortDirection),
        isNull,
        reason: 'an ordinal past the row space is empty, not a wrong row',
      );

      // Occurrence recovery must answer for every row the sweep exposed AND for
      // every file a merged row absorbed (a group member has no row of its own).
      final occurrences =
          <({PlaybackOccurrenceId occurrence, EffectivePlaybackItem row})>[
        for (final item in swept) (occurrence: item.occurrenceId, row: item),
        for (final item in swept)
          if (item.virtualMerged)
            for (final child in item.vmChildren)
              (
                occurrence: PlaybackOccurrenceId(
                  storageId: child.mediaKey.split(':').first,
                  path: child.mediaKey.substring(
                      child.mediaKey.indexOf(':') + 1),
                  occurrenceIndex: child.occurrenceIndex,
                ),
                row: item,
              ),
      ];
      var recovered = 0;
      for (final entry in occurrences) {
        final item = await shared.resolveItemByOccurrenceFor(
            scenarioId: scenarioId, occurrence: entry.occurrence);
        expect(item, isNotNull,
            reason: 'occurrence ${entry.occurrence.occurrenceKey} must resolve');
        expect(item!.occurrenceId.path, entry.occurrence.path,
            reason: 'occurrence ${entry.occurrence.occurrenceKey} path');
        expect(item.occurrenceId.occurrenceIndex,
            entry.occurrence.occurrenceIndex,
            reason: 'occurrence ${entry.occurrence.occurrenceKey} index');
        if (item.virtualMerged) {
          // Covered by the merged row the sweep exposed: same slot, same merged
          // display (title / totals / children).
          expect(item.virtualIndex, entry.row.virtualIndex,
              reason: 'occurrence ${entry.occurrence.occurrenceKey} slot');
          expect(item.media.name, entry.row.media.name,
              reason:
                  'occurrence ${entry.occurrence.occurrenceKey} display name');
        }
        // A plain FILE row wins over the group member covering the same
        // occurrence (`anchorRankOfOccurrence`'s documented tie-break, mirroring
        // the v43 query's two steps), so such an occurrence resolves to its own
        // row and keeps the file's name — nothing more to pin here.
        recovered++;
      }
      expect(recovered, greaterThan(0));
    }

    test('plain folder source: the shared read agrees with the walk', () async {
      await seedA(23);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      final builder = buildResolver(shared: false);
      await builder.buildQueueIndex(scenario.id);
      expect(await sharedDao.read(await indexDao.currentBuildId(scenario.id)),
          isNotNull);
      await expectSharedReads(
          scenarioId: scenario.id, expectLegacyParity: true);
    });

    test('VM groups: the merged rows match the walk, and the reads agree '
        'with each other', () async {
      await seedA(23);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      final rules = [mergeRule()];
      final builder = buildResolver(shared: false, rules: rules);
      await builder.buildQueueIndex(scenario.id);

      // The legacy walk paginates its COMPACTED merge list while the index
      // paginates base slots (a documented difference), so page windows are not
      // comparable — but one page covering everything must yield the same rows.
      final legacy = buildResolver(shared: false, rules: rules);
      final shared = buildResolver(shared: true, rules: rules);
      final bySweep = await shared.resolvePageIndexed(
          scenarioId: scenario.id, page: 0, pageSize: 1000);
      final legacySweep = await legacy.resolvePage(
          scenarioId: scenario.id, page: 0, pageSize: 1000);
      expect(bySweep.items.map(key).toList(),
          legacySweep.items.map(key).toList());

      await expectSharedReads(
          scenarioId: scenario.id, expectLegacyParity: false, rules: rules);
    });

    test('exclude + dedup: the shared read is self-consistent (the walk keeps '
        'its raw space)', () async {
      await seedA(23);
      await seedFiles([for (var i = 0; i < 5; i++) 'A/sub/$i.mp4']);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      // A nested recursive source: its files appear twice, which is what dedup
      // collapses.
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A/sub',
          recursive: true);
      await repo.updateScenario((await repo.getScenario(scenario.id))!
          .copyWith(duplicatePolicy: DuplicatePolicy.deduplicate));
      for (final path in ['A/0002.mp4', 'A/0005.mp4']) {
        await repo.addExcludeRule(
          scenarioId: scenario.id,
          rule: ScenarioExcludeRule(
            id: 0,
            scenarioId: scenario.id,
            kind: ExcludeRuleKind.media,
            storageId: 'st1',
            path: path,
          ),
        );
      }
      final builder = buildResolver(shared: false);
      await builder.buildQueueIndex(scenario.id);
      await expectSharedReads(
          scenarioId: scenario.id, expectLegacyParity: false);
    });

    test('overlapping sources + exclude + VM: the reads agree with each other',
        () async {
      await seedA(12);
      await seedFiles([for (var i = 0; i < 5; i++) 'A/sub/$i.mp4']);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A/sub',
          recursive: true);
      await repo.addExcludeRule(
        scenarioId: scenario.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: scenario.id,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'A/0003.mp4',
        ),
      );
      final rules = [mergeRule(maxItemCount: 4)];
      final builder = buildResolver(shared: false, rules: rules);
      await builder.buildQueueIndex(scenario.id);
      await expectSharedReads(
          scenarioId: scenario.id, expectLegacyParity: false, rules: rules);
    });

    test('shuffled: the shared view agrees with the walk (asc and desc)',
        () async {
      await seedA(23);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      await repo.updateScenario((await repo.getScenario(scenario.id))!
          .copyWith(order: PlaybackOrder.shuffled));
      await repo.updateState(
          ScenarioState(scenarioId: scenario.id, shuffleSeed: 9));
      final builder = buildResolver(shared: false);
      await builder.buildQueueIndex(scenario.id);

      await expectSharedReads(
          scenarioId: scenario.id, expectLegacyParity: true);
      await expectSharedReads(
          scenarioId: scenario.id,
          expectLegacyParity: true,
          sortDirection: SortDirection.desc);
    });

    test('shuffled with a seed changed after the build: the new seed is a view',
        () async {
      await seedA(23);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      await repo.updateScenario((await repo.getScenario(scenario.id))!
          .copyWith(order: PlaybackOrder.shuffled));
      await repo.updateState(
          ScenarioState(scenarioId: scenario.id, shuffleSeed: 9));
      final builder = buildResolver(shared: false);
      await builder.buildQueueIndex(scenario.id);
      // A shuffle refresh: new seed only.
      await repo.updateState(
          ScenarioState(scenarioId: scenario.id, shuffleSeed: 4242));
      await expectSharedReads(
          scenarioId: scenario.id, expectLegacyParity: true);
    });

    test('page boundaries: a group spanning a page edge appears once', () async {
      await seedA(10);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      final rules = [mergeRule(maxItemCount: 5)];
      final builder = buildResolver(shared: false, rules: rules);
      await builder.buildQueueIndex(scenario.id);
      // pageSize 2 while groups absorb 5 slots: most pages are empty, and the
      // group must still appear exactly once across the sweep.
      await expectSharedReads(
          scenarioId: scenario.id, expectLegacyParity: false, rules: rules);
      await expectSharedReads(
          scenarioId: scenario.id,
          expectLegacyParity: false,
          rules: rules,
          pageSize: 2);
    });

    test('an explicit item joins the indexed queue in global order', () async {
      await seedA(5);
      await seedFiles(['B/0009.mp4']);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      await repo.addExplicitItem(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'B/0009.mp4');
      final buildId =
          await buildResolver(shared: false).buildQueueIndex(scenario.id);
      expect(await sharedDao.read(buildId), isNotNull,
          reason: 'an explicit item is representable now');

      final page = await buildResolver(shared: true).resolvePageIndexed(
          scenarioId: scenario.id, page: 0, pageSize: 50);
      expect(page.items.map((i) => i.media.name).toList(), [
        '0000.mp4',
        '0001.mp4',
        '0002.mp4',
        '0003.mp4',
        '0004.mp4',
        '0009.mp4',
      ]);
      expect(page.items.last.explicit, isTrue);
    });

    test('a vanished explicit file becomes the placeholder tail', () async {
      await seedA(3);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      await repo.addExplicitItem(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'B/gone.mp4');
      final buildId =
          await buildResolver(shared: false).buildQueueIndex(scenario.id);
      expect(await sharedDao.read(buildId), isNotNull,
          reason: 'a missing explicit file is a placeholder row, not a gap');

      final page = await buildResolver(shared: true).resolvePageIndexed(
          scenarioId: scenario.id, page: 0, pageSize: 50);
      expect(page.totalItems, 4);
      expect(page.items.take(3).every((i) => i.available), isTrue);
      expect(page.items.last.available, isFalse);
      expect(page.items.last.virtualIndex, 3);
    });

    test('a STALE shared order is refused, never served', () async {
      await seedA(6);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      await buildResolver(shared: false).buildQueueIndex(scenario.id);
      final buildId = await indexDao.currentBuildId(scenario.id);
      expect(await sharedDao.read(buildId), isNotNull);

      // A FRESH resolver each time on purpose: the in-memory LRU is keyed by
      // build id and is invalidated by the store rebuilding under a NEW build id
      // (its signature includes the media revisions), so re-reading here must go
      // back to the persisted guard.
      Future<int> sharedItemCount() async {
        final page = await buildResolver(shared: true)
            .resolvePageIndexed(scenarioId: scenario.id, page: 0, pageSize: 50);
        return page.items.length;
      }

      // Precondition: the shared read really serves this generation.
      expect(await sharedItemCount(), greaterThan(0));

      // Re-stamp every stored order with a DIFFERENT media revision AND a
      // corrupted id sequence. A slice's bitmap selects POSITIONS into that
      // sequence, so a served order would visibly mis-serve; the per-slice rev
      // guard must make the whole index look absent instead.
      final keys =
          await db.customSelect('SELECT order_key FROM media_orders').get();
      expect(keys, isNotEmpty, reason: 'the build must have cached an order');
      for (final row in keys) {
        final key = row.read<String>('order_key');
        final ids = await orderDao.read(key, mediaRev: 0);
        expect(ids, isNotNull);
        await orderDao.write(key, mediaRev: 1,
            ids: Int32List.fromList(ids!.reversed.toList()));
      }
      // The index blob is still there, so a served stale index would look
      // plausible — which is exactly what must not happen.
      expect(await sharedDao.read(buildId), isNotNull);

      // A refused index falls back to the walk: the served order is the NATURAL
      // one, never the reversed sequence the stamp now holds.
      final afterBump = await buildResolver(shared: true)
          .resolvePageIndexed(scenarioId: scenario.id, page: 0, pageSize: 50);
      expect(
        afterBump.items.map((e) => e.media.name).toList(),
        [for (var i = 0; i < 6; i++) '000$i.mp4'],
        reason: 'a stale order must be refused, not serve wrong nodes',
      );
      expect(await sharedItemCount(), 6,
          reason: 'the fallback serves the whole queue, not an empty page');
    });

    test('a FILE source rides along: the shared read and the walk agree',
        () async {
      await seedA(10);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      // Production registers a provider for `file` too, so a single-file source
      // is a real single-element segment, not a placeholder.
      await repo.addSource(
        scenarioId: scenario.id,
        storageId: 'st1',
        path: 'A/0004.mp4',
        kind: ScenarioSourceKind.file,
      );
      final providers = folderAndFile();
      await buildResolver(shared: false, providers: providers)
          .buildQueueIndex(scenario.id);
      expect(await sharedDao.read(await indexDao.currentBuildId(scenario.id)),
          isNotNull,
          reason: 'a one-element segment is trivially ordered');

      await expectSharedReads(
          scenarioId: scenario.id,
          // The file source duplicates A/0004 (already inside the recursive
          // folder source), and the LEGACY walk numbers occurrences PER PAGE
          // (`resolvePage`'s `occurrenceCounts` is local to one call), so it
          // reports #0 for the copy that lands on a later page where the index
          // reports #1. Pre-existing legacy limitation, not an index difference:
          // the reference-free invariants above still hold strictly.
          expectLegacyParity: false,
          providers: providers);
    });

    test('VM search hits describe exactly the queue\'s merged rows', () async {
      await seedA(12);
      await seedFiles([for (var i = 0; i < 5; i++) 'A/sub/$i.mp4']);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A/sub',
          recursive: true);
      await repo.addExcludeRule(
        scenarioId: scenario.id,
        rule: ScenarioExcludeRule(
          id: 0,
          scenarioId: scenario.id,
          kind: ExcludeRuleKind.media,
          storageId: 'st1',
          path: 'A/0003.mp4',
        ),
      );
      final rules = [mergeRule(maxItemCount: 4)];
      await buildResolver(shared: false, rules: rules)
          .buildQueueIndex(scenario.id);
      final buildId = await indexDao.currentBuildId(scenario.id);
      expect(await sharedDao.read(buildId), isNotNull);

      final hits = await buildResolver(shared: true, rules: rules)
          .searchVmGroupsIndexed(scenario.id);
      expect(hits, isNotNull);
      expect(hits!, isNotEmpty, reason: 'the scenario must produce VM groups');

      // The search list and the queue read the SAME persisted generation, so a
      // hit must describe exactly one merged row: same representative file, same
      // segment count, same totals. A drift in any of them is a silent display
      // error (the search row would open a different segment than the queue row).
      final sweep = await buildResolver(shared: true, rules: rules)
          .resolvePageIndexed(
              scenarioId: scenario.id, page: 0, pageSize: 1000);
      final merged = sweep.items.where((i) => i.virtualMerged).toList();
      expect(merged, isNotEmpty);
      expect(hits.length, merged.length);
      for (final row in merged) {
        final hit = hits.singleWhere((h) =>
            h.path == row.occurrenceId.path &&
            h.occurrenceIndex == row.occurrenceId.occurrenceIndex);
        expect(hit.segmentCount, row.vmSegmentCount,
            reason: '${hit.scopeKey} segmentCount');
        expect(hit.totalDurationMs, row.vmTotalDurationMs,
            reason: '${hit.scopeKey} totalDurationMs');
        expect(hit.title, isNotEmpty, reason: '${hit.scopeKey} title');
      }
    });

    // These two prove that what actually serves is the shared index (and, when
    // it cannot, the WALK — never a stale or absent representation), from a FRESH
    // resolver so the in-memory LRU cannot be mistaken for the persisted index.
    test('the reads really come from the shared index: the slots are the '
        'ACCEPTED ones', () async {
      await seedA(10);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      // Excludes compact BOTH spaces now: the index reads them as accepted
      // ranks, the walk reads them as accepted elements — one axis, so the two
      // paths can only be told apart by whether the index is present at all
      // (asserted below by dropping the shared row).
      for (final path in ['A/0001.mp4', 'A/0004.mp4', 'A/0007.mp4']) {
        await repo.addExcludeRule(
          scenarioId: scenario.id,
          rule: ScenarioExcludeRule(
            id: 0,
            scenarioId: scenario.id,
            kind: ExcludeRuleKind.media,
            storageId: 'st1',
            path: path,
          ),
        );
      }
      final buildId =
          await buildResolver(shared: false).buildQueueIndex(scenario.id);
      expect(await sharedDao.read(buildId), isNotNull);

      final shared = await buildResolver(shared: true).resolvePageIndexed(
          scenarioId: scenario.id, page: 0, pageSize: 1000);
      expect(shared.items.map((i) => i.virtualIndex).toSet(),
          {for (var i = 0; i < 7; i++) i},
          reason: 'the shared index serves ACCEPTED slots');
      expect(await buildResolver(shared: true).indexedTotalCount(buildId), 7);

      final legacy = await buildResolver(shared: false).resolvePageIndexed(
          scenarioId: scenario.id, page: 0, pageSize: 1000);
      expect(legacy.items.map((i) => i.virtualIndex).toSet(),
          {for (var i = 0; i < 7; i++) i},
          reason: 'the walk pages the same element axis as the index');

      // Drop the shared row: the very same read now degrades to the walk, which
      // is the proof that the shared index was what served it before.
      await db.customStatement(
          'DELETE FROM scenario_shared_index WHERE build_id = ?', [buildId]);
      final after = await buildResolver(shared: true).resolvePageIndexed(
          scenarioId: scenario.id, page: 0, pageSize: 1000);
      expect(after.items.map(key).toList(), legacy.items.map(key).toList(),
          reason: 'without the shared index the walk serves');
      expect(after.totalItems, legacy.totalItems);
      expect(await buildResolver(shared: true).indexedTotalCount(buildId),
          isNull);
      expect(
        await buildResolver(shared: true).resolveItemAtIndex(scenario.id, 0),
        isNull,
        reason: 'the seek is index-only and degrades with it',
      );
    });

    test('a missing shared order is treated as absent and falls back to the '
        'walk', () async {
      await seedA(20);
      final scenario = await repo.createScenario(name: 'S');
      await repo.addSource(
          scenarioId: scenario.id,
          storageId: 'st1',
          path: 'A',
          recursive: true);
      final buildId = await buildResolver(shared: false).buildQueueIndex(
          scenario.id);
      final expected = await buildResolver(shared: false).resolvePageIndexed(
          scenarioId: scenario.id, page: 0, pageSize: 1000);

      // Drop the shared order the bitmaps index into: without it the positions
      // are meaningless, so the index must look ABSENT rather than serve wrong
      // nodes.
      final blobs = (await sharedDao.read(buildId))!;
      final orderKeys = [
        for (final s in SharedIndexCodec.decodeSlices(blobs.slices).singleSlices) s.orderKey,
      ];
      expect(orderKeys, isNotEmpty);
      for (final orderKey in orderKeys) {
        await orderDao.deleteOrder(orderKey);
      }

      final after = await buildResolver(shared: true).resolvePageIndexed(
          scenarioId: scenario.id, page: 0, pageSize: 1000);
      expect(after.items.map(key).toList(), expected.items.map(key).toList(),
          reason: 'a missing order must fall back, never mis-serve positions');
      expect(after.totalItems, expected.totalItems);
    });
  });
}
