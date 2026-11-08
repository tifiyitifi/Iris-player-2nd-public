import 'dart:io';
import 'dart:math';
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
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/resolver/bit_vector.dart';
import 'package:iris/features/scenario_playback/resolver/merged_order_codec.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/resolver/shared_index_codec.dart';
import 'package:iris/features/scenario_playback/resolver/shared_media_order.dart';
import 'package:iris/models/db/app_database.dart';

/// Scale acceptance for the derived queue index (P7).
///
/// A 500k-entry generation (the queue's index space, matching a 50 万 media
/// library) must serve pages and random seeks in flat time and bounded memory.
/// The assertions bound the O(pageSize)/O(log n) SHAPE rather than a
/// machine-specific latency: a full walk at this size costs seconds, so "last
/// page ≈ first page" is the real regression guard.
///
/// The generation is persisted as a SHARED index (the v43 row tables are
/// retired): two blobs plus the shared order, instead of ~1M rows.
///
/// Override the row count for a quick local run with
/// `$env:IRIS_SCALE = '50000'; flutter test test/scenario_queue_index_scale_test.dart`.
void main() {
  final scale =
      int.tryParse(Platform.environment['IRIS_SCALE'] ?? '') ?? 500000;
  const scenarioId = 'scale';
  const buildId = 1;

  group('derived index scale ($scale rows)', () {
    late Directory tmp;
    late AppDatabase db;
    late ScenarioResolver resolver;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('iris_scale');
      db = AppDatabase(NativeDatabase(File('${tmp.path}/scale.sqlite')));

      // Synthetic generation: one media node + one file row per rank. Built
      // with recursive CTEs so ~1M rows land in two statements instead of a
      // million round trips.
      await db.customStatement('''
        INSERT INTO media_nodes
          (id, storage_id, data_scope_id, path, name, node_kind, media_type,
           path_depth)
        WITH RECURSIVE seq(i) AS (
          SELECT 0 UNION ALL SELECT i + 1 FROM seq WHERE i < $scale - 1
        )
        SELECT i + 1, 'st1', 'st1',
               'A/' || printf('%06d', i) || '.mp4',
               printf('%06d', i) || '.mp4',
               'file', 'video', 2
        FROM seq
      ''');
      // The synthetic generation is the SHARED index (the only persisted
      // representation): every position of the shared order is in the slice and
      // accepted, nothing is absorbed, so the row space is dense with plain file
      // rows. Writing the blobs directly keeps the fixture at two blobs instead of
      // ~1M rows, and the ORDER is the exact sequence the resolver looks up.
      const mediaRev = 1;
      final orderKey = SharedMediaOrder.orderKey(
        storageId: 'st1',
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.asc,
        pathGroupFirst: true,
        // The resolver's own fallback when no browse scope is pinned.
        mediaTypes: const [MediaType.video, MediaType.audio],
      );
      await MediaOrderDao(db).write(orderKey,
          mediaRev: mediaRev,
          ids: Int32List.fromList([for (var i = 1; i <= scale; i++) i]));
      final all = (BitVectorBuilder(scale)
            ..setAll([for (var i = 0; i < scale; i++) i]))
          .build();
      final none = BitVectorBuilder(scale).build();
      await ScenarioSharedIndexDao(db).write(
        buildId,
        baseCount: scale,
        slices: SharedIndexCodec.encodeSlices(SingleBaseOrder(
            [(orderKey: orderKey, mediaRev: mediaRev, bits: all)])),
        accepted: SharedIndexCodec.encodeBitmap(all),
        absorbed: SharedIndexCodec.encodeBitmap(none),
        groupRows: SharedIndexCodec.encodeGroups(const []),
        placeholders: SharedIndexCodec.encodePlaceholders(const {}),
        occurrence: SharedIndexCodec.encodeIntMap(const {}),
        flags: SharedIndexCodec.encodeIntMap(const {}),
      );
      await ScenarioQueueIndexDao(db).writeBuildMeta(
        scenarioId: scenarioId,
        buildId: buildId,
        baseCount: scale,
        entryCount: scale,
      );

      resolver = ScenarioResolver(
        repo: ScenarioRepository(
          scenariosDao: ScenariosDao(db),
          sourcesDao: ScenarioSourcesDao(db),
          itemsDao: ScenarioExplicitItemsDao(db),
          excludesDao: ScenarioExcludesDao(db),
          statesDao: ScenarioStatesDao(db),
        ),
        nodeRepo: MediaNodeRepository(MediaNodesDao(db)),
        queueIndexDao: ScenarioQueueIndexDao(db),
        mediaOrderDao: MediaOrderDao(db),
        sharedIndexDao: ScenarioSharedIndexDao(db),
        mediaRevisionProvider: (_) async => mediaRev,
      );
    });

    tearDownAll(() async {
      await db.close();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<int> micros(Future<void> Function() run) async {
      final sw = Stopwatch()..start();
      await run();
      sw.stop();
      return sw.elapsedMicroseconds;
    }

    int p95(List<int> samples) {
      final sorted = [...samples]..sort();
      return sorted[((sorted.length - 1) * 0.95).round()];
    }

    test('page fetch stays flat across the whole generation', () async {
      const pageSize = 50;
      final pageCount = scale ~/ pageSize;
      // Warm up the statement cache.
      await resolver.resolvePageIndexed(
          scenarioId: scenarioId, page: 0, pageSize: pageSize);

      final first = await micros(() async {
        await resolver.resolvePageIndexed(
            scenarioId: scenarioId, page: 0, pageSize: pageSize);
      });
      final last = await micros(() async {
        await resolver.resolvePageIndexed(
            scenarioId: scenarioId, page: pageCount - 1, pageSize: pageSize);
      });

      final rnd = Random(7);
      final samples = <int>[];
      for (var i = 0; i < 60; i++) {
        final page = rnd.nextInt(pageCount);
        samples.add(await micros(() async {
          final result = await resolver.resolvePageIndexed(
              scenarioId: scenarioId, page: page, pageSize: pageSize);
          expect(result.items, hasLength(pageSize));
        }));
      }
      final p = p95(samples);
      // ignore: avoid_print
      print('[scale:$scale] page p95=${(p / 1000).toStringAsFixed(2)}ms '
          'first=${(first / 1000).toStringAsFixed(2)}ms '
          'last=${(last / 1000).toStringAsFixed(2)}ms');

      // A full walk at this size is seconds; the last page must not approach
      // it. The +15ms floor absorbs timer noise on tiny first readings.
      expect(last, lessThan(first * 6 + 15000),
          reason: 'the last page must not cost like a full walk');
      expect(p, lessThan(300000), reason: 'page p95 under 300ms');
    });

    test('random single-item seeks stay flat', () async {
      await resolver.resolveItemAtIndex(scenarioId, 0);
      final first = await micros(() async {
        await resolver.resolveItemAtIndex(scenarioId, 0);
      });
      final last = await micros(() async {
        await resolver.resolveItemAtIndex(scenarioId, scale - 1);
      });

      final rnd = Random(11);
      final samples = <int>[];
      for (var i = 0; i < 60; i++) {
        final ordinal = rnd.nextInt(scale);
        samples.add(await micros(() async {
          final item = await resolver.resolveItemAtIndex(scenarioId, ordinal);
          expect(item, isNotNull);
        }));
      }
      final p = p95(samples);
      // ignore: avoid_print
      print('[scale:$scale] seek p95=${(p / 1000).toStringAsFixed(2)}ms '
          'first=${(first / 1000).toStringAsFixed(2)}ms '
          'last=${(last / 1000).toStringAsFixed(2)}ms');

      expect(last, lessThan(first * 6 + 15000),
          reason: 'seeking the tail must not walk the stream');
      expect(p, lessThan(300000), reason: 'seek p95 under 300ms');
    });

    test('content signature stays constant (never scans the media set)',
        () async {
      // ensureQueueIndex recomputes this on every read path; it must stay a
      // handful of small-table reads, not a scan proportional to the library.
      await resolver.definitionSignature(scenarioId);
      final samples = <int>[];
      for (var i = 0; i < 50; i++) {
        samples.add(await micros(() async {
          await resolver.definitionSignature(scenarioId);
        }));
      }
      final p = p95(samples);
      // ignore: avoid_print
      print('[scale:$scale] signature p95=${(p / 1000).toStringAsFixed(2)}ms');
      expect(p, lessThan(100000),
          reason: 'signature must not scan the media set');
    });

    test('sweeping the whole generation keeps memory bounded', () async {
      // A whole-generation sweep in bounded pages must complete without
      // materialising the stream (the pre-index behaviour OOM'd here).
      final rssBefore = ProcessInfo.currentRss;
      const pageSize = 500;
      final pageCount = (scale + pageSize - 1) ~/ pageSize;
      var seen = 0;
      for (var page = 0; page < pageCount; page++) {
        final result = await resolver.resolvePageIndexed(
            scenarioId: scenarioId, page: page, pageSize: pageSize);
        seen += result.items.length;
      }
      final rssDelta = ProcessInfo.currentRss - rssBefore;
      // ignore: avoid_print
      print('[scale:$scale] sweep pages=$pageCount seen=$seen '
          'rssDelta=${(rssDelta / (1024 * 1024)).toStringAsFixed(1)}MB');

      expect(seen, scale);
      expect(rssDelta, lessThan(300 * 1024 * 1024),
          reason: 'a full sweep must not accumulate the stream');
    });
  });

  /// The persisted shapes are a STORAGE budget, so they are asserted at the
  /// same 50 万 scale as the read budget above: the merged interleave must not
  /// approach the 4 B/entry id list it replaced, and the element permutation
  /// must stay cheap.
  group('encoding budgets ($scale entries)', () {
    test('the merged base order stays under 2 bytes per entry', () {
      const streamCount = 3;
      final counts = List<int>.filled(streamCount, 0);
      final entries = <({int stream, int rank})>[];
      for (var i = 0; i < scale; i++) {
        final stream = i % streamCount;
        entries.add((stream: stream, rank: counts[stream]++));
      }
      final bytes = MergedOrder.encodeEntries(
        streams: [
          for (var s = 0; s < streamCount; s++)
            MergedOrderStream(
              orderKey: 'k$s',
              mediaRev: 1,
              count: counts[s],
              // Dense fixture: every stream contributes its order 1:1.
              orderLength: counts[s],
            ),
        ],
        entries: entries,
      );
      final perEntry = bytes.length / scale;
      // ignore: avoid_print
      print('[scale:$scale] merged order '
          '${perEntry.toStringAsFixed(3)}B/entry');
      expect(perEntry, lessThan(2.0),
          reason: 'the interleave must not approach the 4 B id list');

      final decoded = MergedOrder.decode(bytes);
      expect(decoded, isNotNull);
      expect(decoded!.length, scale);
      // Random access decodes at most one checkpoint block.
      expect(decoded.decodeBudgetAt(scale - 1),
          lessThanOrEqualTo(MergedOrder.defaultCheckInterval));
      expect(decoded.at(scale - 1), entries.last);
    });

    test('a single-source bitmap stays under 0.13 bytes per entry', () {
      final bits = (BitVectorBuilder(scale)
            ..setAll([for (var i = 0; i < scale; i++) i]))
          .build();
      final bytes = SharedIndexCodec.encodeSlices(SingleBaseOrder(
          [(orderKey: 'k', mediaRev: 1, bits: bits)]));
      final perEntry = bytes.length / scale;
      // ignore: avoid_print
      print('[scale:$scale] single bitmap '
          '${perEntry.toStringAsFixed(4)}B/entry');
      expect(perEntry, lessThan(0.13));
    });

    test('the element permutation round-trips and stays small', () {
      // A reversed permutation is the worst case for the zigzag delta (every
      // step is -1), i.e. still one byte per entry.
      final order = Int32List.fromList(
          [for (var i = 0; i < scale; i++) scale - 1 - i]);
      final bytes = SharedIndexCodec.encodeElementOrder(order);
      final perEntry = bytes.length / scale;
      // ignore: avoid_print
      print('[scale:$scale] element order '
          '${perEntry.toStringAsFixed(3)}B/entry');
      expect(perEntry, lessThan(3.0));
      expect(SharedIndexCodec.decodeElementOrder(bytes), order);
    });
  });
}
