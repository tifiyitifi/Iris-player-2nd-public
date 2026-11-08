import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
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
import 'package:iris/features/scenario_playback/resolver/bit_vector.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/resolver/shared_index_codec.dart';
import 'package:iris/features/scenario_playback/resolver/shared_row_overlay.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/models/db/app_database.dart';

/// Measures the END-TO-END cost of the index-backed VM search
/// (`searchVmGroupsIndexed` → `_SharedRowSource.groupHeaders`) for one
/// whole-library generation, INCLUDING the per-group representative node
/// fetches that ⑥ would depend on.
///
///   `$env:IRIS_SCALE='200000'; flutter test test/shared_index_search_probe_test.dart`
///
/// The shape matches `shared_index_storage_probe_test.dart`: n files, a rule
/// folding them `IRIS_GROUP`-to-a-group, every member present in `media_nodes`
/// (so the headers are fully derived instead of dropped). It measures two sizes
/// (n and 2n) so the printout answers "does it grow linearly with the group
/// count?" instead of reporting a single number that says nothing about scaling.
void main() {
  test('index-backed VM search cost', () async {
    final n = int.tryParse(Platform.environment['IRIS_SCALE'] ?? '') ?? 20000;
    final membersPer =
        int.tryParse(Platform.environment['IRIS_GROUP'] ?? '') ?? 10;
    final small = await _measure(n: n, membersPer: membersPer);
    final large = await _measure(n: n * 2, membersPer: membersPer);
    final perGroup = small.ms / small.groups;
    // ignore: avoid_print
    print('IRIS_SCALE=$n IRIS_GROUP=$membersPer | '
        'n=${small.n} groups=${small.groups} search=${small.ms.toStringAsFixed(0)}ms '
        '(${perGroup.toStringAsFixed(3)}ms/group, ${small.hits} hits) | '
        'n=${large.n} groups=${large.groups} search=${large.ms.toStringAsFixed(0)}ms '
        '(${(large.ms / large.groups).toStringAsFixed(3)}ms/group, ${large.hits} hits) | '
        '2x groups took ${(large.ms / (small.ms == 0 ? 1 : small.ms)).toStringAsFixed(2)}x');
    // Each group yields exactly one hit, in both runs, so the measurement is not
    // silently dropping representatives. (Not `2 * small.hits`: an odd n floors
    // the group count, so the two sizes need not differ by exactly 2x.)
    expect(small.hits, small.groups);
    expect(large.hits, large.groups);
  });
}

Future<({int n, int groups, int hits, double ms})> _measure({
  required int n,
  required int membersPer,
}) async {
  final dir = Directory.systemTemp.createTempSync('iris_search_probe');
  final db = AppDatabase(NativeDatabase(File('${dir.path}/probe.sqlite')));
  try {
    const ruleId = '00000000-0000-4000-8000-000000000000';
    const scenarioId = 'probe-scenario';
    const buildId = 1;
    final groups = n ~/ membersPer;
    String pathOf(int i) => 'A/${i.toString().padLeft(6, '0')}.mp4';
    String nameOf(int i) => '${i.toString().padLeft(6, '0')}.mp4';

    // Real rows for EVERY member: the header needs the first/last
    // representative's file fields, so the probe must pay for that fetch.
    await MediaNodesDao(db).batchUpsert([
      for (var i = 1; i <= n; i++)
        MediaNodesTableCompanion(
          id: Value(i),
          storageId: const Value('st1'),
          path: Value(pathOf(i)),
          name: Value(nameOf(i)),
          nodeKind: const Value(MediaNodeKind.file),
          mediaType: const Value(MediaType.video),
          durationMs: const Value(60000),
          width: const Value(1920),
          height: const Value(1080),
          uri: Value('file:///media/${pathOf(i)}'),
        ),
    ]);

    final orders = MediaOrderDao(db);
    await orders.write('probe',
        mediaRev: 1, ids: Int32List.fromList([for (var i = 1; i <= n; i++) i]));

    final all = (BitVectorBuilder(n)..setAll([for (var i = 0; i < n; i++) i]))
        .build();
    // Every file folds into a group ⇒ every rank is absorbed into a group row.
    final groupRows = [
      for (var g = 0; g < groups; g++)
        SharedGroupRow(
          anchorRank: g * membersPer,
          ruleId: ruleId,
          rootPath: '/some/path',
          chunkNo: g + 1,
          members: Int32List.fromList([
            for (var m = 0; m < membersPer; m++) g * membersPer + m + 1,
          ]),
          totalDurationMs: 60000 * membersPer,
        ),
    ];

    final sharedDao = ScenarioSharedIndexDao(db);
    await sharedDao.write(
      buildId,
      baseCount: n,
      slices: SharedIndexCodec.encodeSlices(SingleBaseOrder(
          [(orderKey: 'probe', mediaRev: 1, bits: all)])),
      accepted: SharedIndexCodec.encodeBitmap(all),
      absorbed: SharedIndexCodec.encodeBitmap(all),
      groupRows: SharedIndexCodec.encodeGroups(groupRows),
      placeholders: SharedIndexCodec.encodePlaceholders(const {}),
      occurrence: SharedIndexCodec.encodeIntMap(const {}),
      flags: SharedIndexCodec.encodeIntMap(const {}),
    );
    final indexDao = ScenarioQueueIndexDao(db);
    await indexDao.writeBuildMeta(
      scenarioId: scenarioId,
      buildId: buildId,
      baseCount: n,
      entryCount: groups,
    );

    final resolver = ScenarioResolver(
      repo: ScenarioRepository(
        scenariosDao: ScenariosDao(db),
        sourcesDao: ScenarioSourcesDao(db),
        itemsDao: ScenarioExplicitItemsDao(db),
        excludesDao: ScenarioExcludesDao(db),
        statesDao: ScenarioStatesDao(db),
      ),
      nodeRepo: MediaNodeRepository(MediaNodesDao(db)),
      scopedMediaTypes: () => null,
      vmRulesProvider: () async => [
        VirtualMediaRule(
          id: ruleId,
          name: 'R',
          matchMode: VmMatchMode.specifiedDirRecursive,
          paths: const ['A'],
          boundary: VmBoundaryMode.sameDirOnly,
          useDurationCap: false,
          useCountCap: true,
          maxItemCount: membersPer,
          enabled: true,
        ),
      ],
      queueIndexDao: indexDao,
      mediaOrderDao: orders,
      sharedIndexDao: sharedDao,
      mediaRevisionProvider: (_) async => 1,
      useSharedIndexRead: true,
    );

    final watch = Stopwatch()..start();
    final hits = await resolver.searchVmGroupsIndexed(scenarioId);
    watch.stop();
    // `isNotNull` is exported by drift too; a plain check keeps the imports sane.
    if (hits == null) {
      throw StateError('the probe must exercise the shared path');
    }
    return (
      n: n,
      groups: groups,
      hits: hits.length,
      ms: watch.elapsedMicroseconds / 1000,
    );
  } finally {
    await db.close();
    dir.deleteSync(recursive: true);
  }
}
