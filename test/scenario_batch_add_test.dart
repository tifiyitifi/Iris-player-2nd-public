import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';

/// The drag-drop append/override paths add a whole batch of explicit files and
/// sources in ONE transaction. These cover the batch repository primitives that
/// replaced the O(N²) per-item loop (each add used to re-read every row).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
    useAppStore();
    await useAppStore().initialized;
  });

  tearDownAll(() => db.close());

  setUp(() async {
    final repo = DbModule.scenarioRepo;
    final sys = await repo.ensureSystemPlayingScenario();
    await repo.clearExplicitItems(sys.id);
    await repo.clearSources(sys.id);
  });

  group('addExplicitItems', () {
    test('assigns sequential addOrder in list order', () async {
      final repo = DbModule.scenarioRepo;
      final sys = await repo.ensureSystemPlayingScenario();

      await repo.addExplicitItems(
        scenarioId: sys.id,
        items: const [
          (storageId: 's', path: 'a.mp4', batchId: null, mediaId: null, uiSortKey: null),
          (storageId: 's', path: 'b.mp4', batchId: null, mediaId: null, uiSortKey: null),
          (storageId: 's', path: 'c.mp4', batchId: null, mediaId: null, uiSortKey: null),
        ],
      );

      final items = await repo.getExplicitItems(sys.id);
      expect(items.map((e) => e.path).toList(), ['a.mp4', 'b.mp4', 'c.mp4']);
      expect(items.map((e) => e.addOrder).toList(), [1, 2, 3]);
    });

    test('continues addOrder from the rows already present', () async {
      final repo = DbModule.scenarioRepo;
      final sys = await repo.ensureSystemPlayingScenario();
      await repo.addExplicitItem(
        scenarioId: sys.id,
        storageId: 's',
        path: 'a.mp4',
      );

      await repo.addExplicitItems(
        scenarioId: sys.id,
        items: const [
          (storageId: 's', path: 'b.mp4', batchId: null, mediaId: null, uiSortKey: null),
          (storageId: 's', path: 'c.mp4', batchId: null, mediaId: null, uiSortKey: null),
        ],
      );

      final items = await repo.getExplicitItems(sys.id);
      expect(items.map((e) => e.addOrder).toList(), [1, 2, 3]);
    });

    test('a duplicated path collapses to one row (unique constraint)', () async {
      final repo = DbModule.scenarioRepo;
      final sys = await repo.ensureSystemPlayingScenario();

      await repo.addExplicitItems(
        scenarioId: sys.id,
        items: const [
          (storageId: 's', path: 'a.mp4', batchId: null, mediaId: null, uiSortKey: null),
          (storageId: 's', path: 'a.mp4', batchId: null, mediaId: null, uiSortKey: null),
        ],
      );

      final items = await repo.getExplicitItems(sys.id);
      expect(items, hasLength(1));
    });

    test('empty input is a no-op', () async {
      final repo = DbModule.scenarioRepo;
      final sys = await repo.ensureSystemPlayingScenario();
      await repo.addExplicitItems(scenarioId: sys.id, items: const []);
      expect(await repo.getExplicitItems(sys.id), isEmpty);
    });
  });

  group('addExplicitItem (single)', () {
    // The table's UNIQUE(scenario_id, storage_id, path) is not the PK, so the
    // single-add entry point must skip an already-present item exactly like the
    // batch form — an insertOnConflictUpdate on it used to throw.
    test('re-adding the same file is idempotent, not a constraint error',
        () async {
      final repo = DbModule.scenarioRepo;
      final sys = await repo.ensureSystemPlayingScenario();

      await repo.addExplicitItem(
          scenarioId: sys.id, storageId: 's', path: 'a.mp4');
      await repo.addExplicitItem(
          scenarioId: sys.id, storageId: 's', path: 'a.mp4');

      expect(await repo.getExplicitItems(sys.id), hasLength(1));
    });

    test('a non-canonical slash form is the same logical item', () async {
      final repo = DbModule.scenarioRepo;
      final sys = await repo.ensureSystemPlayingScenario();

      await repo.addExplicitItem(
          scenarioId: sys.id, storageId: 's', path: 'shows/a.mp4');
      await repo.addExplicitItem(
          scenarioId: sys.id, storageId: 's', path: '/shows/a.mp4');

      expect(await repo.getExplicitItems(sys.id), hasLength(1));
    });

    test('a genuinely new file after a skipped duplicate continues addOrder',
        () async {
      final repo = DbModule.scenarioRepo;
      final sys = await repo.ensureSystemPlayingScenario();

      await repo.addExplicitItem(
          scenarioId: sys.id, storageId: 's', path: 'a.mp4');
      await repo.addExplicitItem(
          scenarioId: sys.id, storageId: 's', path: 'a.mp4');
      await repo.addExplicitItem(
          scenarioId: sys.id, storageId: 's', path: 'b.mp4');

      final items = await repo.getExplicitItems(sys.id);
      expect(items.map((e) => e.path).toList(), ['a.mp4', 'b.mp4']);
      expect(items.map((e) => e.addOrder).toList(), [1, 2]);
    });
  });

  group('addSources', () {
    test('adds every source with increasing sortOrder', () async {
      final repo = DbModule.scenarioRepo;
      final sys = await repo.ensureSystemPlayingScenario();

      await repo.addSources(
        scenarioId: sys.id,
        specs: const [
          (storageId: 's', path: 'a', recursive: true, kind: ScenarioSourceKind.folder),
          (storageId: 's', path: 'b', recursive: false, kind: ScenarioSourceKind.folder),
        ],
      );

      final sources = await repo.getSources(sys.id);
      expect(sources.map((e) => e.path).toList(), ['a', 'b']);
      expect(sources.map((e) => e.sortOrder).toList(), [0, 1]);
      expect(sources.first.recursive, isTrue);
      expect(sources.last.recursive, isFalse);
    });

    test('a duplicate spec collapses to one row', () async {
      final repo = DbModule.scenarioRepo;
      final sys = await repo.ensureSystemPlayingScenario();

      await repo.addSources(
        scenarioId: sys.id,
        specs: const [
          (storageId: 's', path: 'a', recursive: true, kind: ScenarioSourceKind.folder),
          (storageId: 's', path: 'a', recursive: true, kind: ScenarioSourceKind.folder),
        ],
      );

      expect(await repo.getSources(sys.id), hasLength(1));
    });

    test('promotes a stored non-recursive source when re-added recursively',
        () async {
      final repo = DbModule.scenarioRepo;
      final sys = await repo.ensureSystemPlayingScenario();

      await repo.addSources(
        scenarioId: sys.id,
        specs: const [
          (storageId: 's', path: 'a', recursive: false, kind: ScenarioSourceKind.folder),
        ],
      );
      await repo.addSources(
        scenarioId: sys.id,
        specs: const [
          (storageId: 's', path: 'a', recursive: true, kind: ScenarioSourceKind.folder),
        ],
      );

      final sources = await repo.getSources(sys.id);
      expect(sources, hasLength(1));
      expect(sources.single.recursive, isTrue);
    });

    test('never downgrades a stored recursive source to non-recursive', () async {
      final repo = DbModule.scenarioRepo;
      final sys = await repo.ensureSystemPlayingScenario();

      await repo.addSources(
        scenarioId: sys.id,
        specs: const [
          (storageId: 's', path: 'a', recursive: true, kind: ScenarioSourceKind.folder),
        ],
      );
      await repo.addSources(
        scenarioId: sys.id,
        specs: const [
          (storageId: 's', path: 'a', recursive: false, kind: ScenarioSourceKind.folder),
        ],
      );

      final sources = await repo.getSources(sys.id);
      expect(sources, hasLength(1));
      expect(sources.single.recursive, isTrue);
    });

    test('a recursive spec promotes a non-recursive sibling within the batch',
        () async {
      final repo = DbModule.scenarioRepo;
      final sys = await repo.ensureSystemPlayingScenario();

      await repo.addSources(
        scenarioId: sys.id,
        specs: const [
          (storageId: 's', path: 'a', recursive: false, kind: ScenarioSourceKind.folder),
          (storageId: 's', path: 'a', recursive: true, kind: ScenarioSourceKind.folder),
        ],
      );

      final sources = await repo.getSources(sys.id);
      expect(sources, hasLength(1));
      expect(sources.single.recursive, isTrue);
    });
  });
}
