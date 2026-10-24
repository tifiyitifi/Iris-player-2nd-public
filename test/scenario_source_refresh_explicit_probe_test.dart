import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/actions/explicit_file_probe.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_explicit_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/scan/service/scenario_source_refresh_service.dart';
import 'package:iris/models/storages/storage.dart';

/// The panel action ("Rescan source") must refresh EVERYTHING the queue shows:
/// the sources AND the manually added (explicit) items. Sources are re-probed
/// by the directory scan; explicit items are NOT sources, so the ones the scan
/// does not cover need their own targeted probe — otherwise their metadata is
/// never refreshed (observed: 19 manually added rows kept a poisoned duration
/// after "Rescan source" reported success).
void main() {
  Storage storage({String id = 'st1', String base = '/mnt/media'}) =>
      LocalStorage(
        id: id,
        type: StorageType.internal,
        name: id,
        basePath: base.split('/'),
      );

  ScenarioSource folder(
    String path, {
    String storageId = 'st1',
    bool recursive = true,
  }) =>
      ScenarioSource(
        id: 1,
        scenarioId: 's',
        storageId: storageId,
        path: path,
        recursive: recursive,
        sourceKind: ScenarioSourceKind.folder,
      );

  ScenarioExplicitItem explicit(String path, {String storageId = 'st1'}) =>
      ScenarioExplicitItem(
        id: 1,
        scenarioId: 's',
        storageId: storageId,
        path: path,
      );

  group('pathInsideRoot', () {
    test('a segment prefix covers descendants', () {
      expect(
        pathInsideRoot(
          filePath: '/mnt/media/20260610/001/[X] a.mp4',
          rootPath: '/mnt/media/20260610/001',
        ),
        isTrue,
      );
    });

    test('a root does NOT cover a longer sibling with the same prefix', () {
      // …/001 must not swallow …/0010 or …/001-backup.
      expect(
        pathInsideRoot(
          filePath: '/mnt/media/20260610/0010/a.mp4',
          rootPath: '/mnt/media/20260610/001',
        ),
        isFalse,
      );
      expect(
        pathInsideRoot(
          filePath: '/mnt/media/20260610/001-backup/a.mp4',
          rootPath: '/mnt/media/20260610/001',
        ),
        isFalse,
      );
    });

    test('the root itself and an empty root', () {
      expect(
        pathInsideRoot(filePath: '/mnt/media/20260610', rootPath: '/mnt/media/20260610'),
        isTrue,
      );
      expect(pathInsideRoot(filePath: '/mnt/media/a.mp4', rootPath: ''), isTrue);
    });

    test('foldCase compares case-insensitively (Windows/SMB)', () {
      expect(
        pathInsideRoot(
          filePath: r'E:\YB\20260610\a.mp4',
          rootPath: r'e:\yb\20260610',
        ),
        isFalse,
      );
      expect(
        pathInsideRoot(
          filePath: r'E:\YB\20260610\a.mp4',
          rootPath: r'e:\yb\20260610',
          foldCase: true,
        ),
        isTrue,
      );
    });
  });

  group('planSourceRefresh — explicit probe targets', () {
    test('explicit items INSIDE a scanned root are not probed twice', () {
      final plan = planSourceRefresh(
        sources: [folder('/mnt/media/20260610')],
        explicitItems: [explicit('/mnt/media/20260610/a.mp4')],
        storageById: {'st1': storage()},
        nodeWeightByStorage: const {},
      );

      expect(plan.units, hasLength(1));
      expect(plan.units.single.rootPaths, isNotEmpty);
      expect(plan.units.single.explicitProbeTargets, isEmpty);
    });

    test('explicit items OUTSIDE every root become probe targets', () {
      final plan = planSourceRefresh(
        sources: [folder('/mnt/media/20260610/001')],
        explicitItems: [
          explicit('/mnt/media/20260610/001/covered.mp4'),
          explicit('/mnt/media/20260610/outside.mp4'),
        ],
        storageById: {'st1': storage()},
        nodeWeightByStorage: const {},
      );

      final targets = plan.units.single.explicitProbeTargets;
      expect(targets.map((e) => e.path), ['/mnt/media/20260610/outside.mp4']);
    });

    test('an explicit-only storage probes all of its items (no roots)',
        () {
      final plan = planSourceRefresh(
        sources: const [],
        explicitItems: [
          explicit('/mnt/media/x/a.mp4'),
          explicit('/mnt/media/y/b.mp4'),
        ],
        storageById: {'st1': storage()},
        nodeWeightByStorage: const {},
      );

      expect(plan.units.single.rootPaths, isEmpty);
      expect(plan.units.single.explicitProbeTargets, hasLength(2));
    });

    test('items on a deleted storage are dropped, never probed', () {
      final plan = planSourceRefresh(
        sources: const [],
        explicitItems: [explicit('/mnt/media/a.mp4', storageId: 'gone')],
        storageById: {'st1': storage()},
        nodeWeightByStorage: const {},
      );

      expect(plan.units, isEmpty);
    });
  });

  group('probeUncoveredExplicitFiles', () {
    ScenarioSourceRefreshUnitSpec unit({
      required List<ScenarioExplicitItem> targets,
    }) =>
        ScenarioSourceRefreshUnitSpec(
          storage: storage(),
          rootPaths: const ['/mnt/media/20260610/001'],
          directories: const [],
          explicitItems: targets,
          explicitProbeTargets: targets,
          weight: 1,
        );

    test('probes exactly the uncovered, still-present items', () async {
      final outside = explicit('/mnt/media/20260610/outside.mp4');
      final probedBatches = <List<ExplicitFileProbeTarget>>[];

      final service = ScenarioSourceRefreshService(
        probeExplicit: (targets) async {
          probedBatches.add(targets);
          return (touchedStorages: {'st1'}, written: targets.length);
        },
      );

      final written = await service.probeUncoveredExplicitFiles(
        unit(targets: [outside]),
        presentPaths: {'/mnt/media/20260610/outside.mp4'},
      );

      expect(written, 1);
      expect(probedBatches, hasLength(1));
      // The write-back path is the canonical DB form (no leading slash), the
      // same shape `rescanFile` uses.
      expect(probedBatches.single.map((t) => t.path),
          ['mnt/media/20260610/outside.mp4']);
      expect(probedBatches.single.single.storageId, 'st1');
    });

    test('a file the existence check did not confirm is never probed',
        () async {
      var calls = 0;
      final service = ScenarioSourceRefreshService(
        probeExplicit: (targets) async {
          calls++;
          return (touchedStorages: const <String>{}, written: 0);
        },
      );

      final written = await service.probeUncoveredExplicitFiles(
        unit(targets: [explicit('/mnt/media/20260610/gone.mp4')]),
        // Parent listing failed / file absent → not in the present set.
        presentPaths: const <String>{},
      );

      expect(written, 0);
      expect(calls, 0);
    });

    test('no targets means no probe pass at all', () async {
      var calls = 0;
      final service = ScenarioSourceRefreshService(
        probeExplicit: (targets) async {
          calls++;
          return (touchedStorages: const <String>{}, written: 0);
        },
      );

      final written = await service.probeUncoveredExplicitFiles(
        unit(targets: const []),
        presentPaths: const <String>{},
      );

      expect(written, 0);
      expect(calls, 0);
    });
  });
}
