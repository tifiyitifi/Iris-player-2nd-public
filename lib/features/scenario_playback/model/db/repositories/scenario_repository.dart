import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_shared_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_explicit_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_state.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_lifetime.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:uuid/uuid.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyScenario);

/// Aggregates all scenario DAOs.
///
/// Scenarios are fully owned by the Scenario system: sources, explicit items,
/// exclude rules and per-scenario state all cascade with a Scenario.
///
/// The SystemPlayingScenario is a plain [Scenario] row with
/// [ScenarioKind.systemPlaying] (A1) — no parallel class.
class ScenarioRepository {
  final ScenariosDao scenariosDao;
  final ScenarioSourcesDao sourcesDao;
  final ScenarioExplicitItemsDao itemsDao;
  final ScenarioExcludesDao excludesDao;
  final ScenarioStatesDao statesDao;

  ScenarioRepository({
    required this.scenariosDao,
    required this.sourcesDao,
    required this.itemsDao,
    required this.excludesDao,
    required this.statesDao,
  });

  /// The underlying [AppDatabase], used for transactional command batching.
  AppDatabase get db => sourcesDao.attachedDatabase;

  static const String systemPlayingScenarioName = 'Playing';

  // ── Scenario CRUD ──

  Future<List<Scenario>> getAllScenarios() => scenariosDao.getAll();

  Future<Scenario?> getScenario(String id) => scenariosDao.getById(id);

  Future<Scenario?> getSystemPlayingScenario() =>
      scenariosDao.getByType(ScenarioKind.systemPlaying);

  /// Ensures the single SYSTEM_PLAYING row exists (idempotent, C2/E4).
  Future<Scenario> ensureSystemPlayingScenario() async {
    final existing = await scenariosDao.getByType(ScenarioKind.systemPlaying);
    if (existing != null) return existing;

    final now = DateTime.now();
    final scenario = Scenario(
      id: const Uuid().v4(),
      name: systemPlayingScenarioName,
      type: ScenarioKind.systemPlaying,
      version: null,
      createdAt: now,
      updatedAt: now,
    );
    await scenariosDao.upsert(scenario);
    await _ensureState(scenario.id);
    areaKeyLog.i('Created SystemPlayingScenario: ${scenario.id}');
    return scenario;
  }

  /// Creates a fresh, dedicated workspace for ONE custom desktop entry
  /// (`ScenarioKind.entryWorkspace`). Unlike [ensureSystemPlayingScenario]
  /// there can be many of these, so it always creates a new row; the caller
  /// persists the id on the owning entry and reuses it afterwards.
  Future<Scenario> createEntryWorkspace() async {
    final now = DateTime.now();
    final scenario = Scenario(
      id: const Uuid().v4(),
      name: 'Entry workspace',
      type: ScenarioKind.entryWorkspace,
      version: null,
      createdAt: now,
      updatedAt: now,
    );
    await scenariosDao.upsert(scenario);
    await _ensureState(scenario.id);
    areaKeyLog.i('Created entry workspace: ${scenario.id}');
    return scenario;
  }

  /// Removes an entry workspace and every record it owns. Unlike
  /// [deleteScenario] this bypasses the userSaved guard — the row is internal
  /// and dies with its owning entry.
  Future<void> deleteEntryWorkspace(String id) async {
    await db.transaction(() async {
      await sourcesDao.deleteByScenario(id);
      await itemsDao.deleteByScenario(id);
      await excludesDao.deleteByScenario(id);
      await statesDao.deleteByScenario(id);
      await scenariosDao.deleteScenario(id);
    });
  }

  Future<Scenario> createScenario({
    required String name,
    String? description,
  }) async {
    final now = DateTime.now();
    final scenario = Scenario(
      id: const Uuid().v4(),
      name: name,
      description: description,
      type: ScenarioKind.userSaved,
      version: 0,
      createdAt: now,
      updatedAt: now,
    );
    await scenariosDao.upsert(scenario);
    await _ensureState(scenario.id);
    return scenario;
  }

  Future<void> renameScenario(String id, String name) async {
    final scenario = await scenariosDao.getById(id);
    if (scenario == null) return;
    await scenariosDao.upsert(
      scenario.copyWith(name: name, updatedAt: DateTime.now()),
    );
  }

  Future<void> updateScenario(Scenario scenario) =>
      scenariosDao.upsert(scenario.copyWith(updatedAt: DateTime.now()));

  /// Bumps the version of a userSaved Scenario (structural edit).
  Future<void> bumpVersion(String id) async {
    final scenario = await scenariosDao.getById(id);
    if (scenario == null || scenario.type != ScenarioKind.userSaved) return;
    await scenariosDao.upsert(
      scenario.copyWith(
          version: (scenario.version ?? 0) + 1, updatedAt: DateTime.now()),
    );
  }

  /// Deletes a user-created scenario and all its owned records (matrix:
  /// Delete × 4). The internal workspace rows (systemPlaying / entryWorkspace)
  /// cannot be deleted through this path.
  ///
  /// The derived queue index is dropped with it: the rows are keyed by a
  /// scenario id that no longer exists, so nothing would ever read or evict them
  /// again.
  Future<bool> deleteScenario(String id) async {
    final scenario = await scenariosDao.getById(id);
    if (scenario == null) return false;
    if (scenario.type != ScenarioKind.userSaved) return false;

    await db.transaction(() async {
      await sourcesDao.deleteByScenario(id);
      await itemsDao.deleteByScenario(id);
      await excludesDao.deleteByScenario(id);
      await statesDao.deleteByScenario(id);
      await scenariosDao.deleteScenario(id);
    });
    final indexDao = ScenarioQueueIndexDao(db);
    await indexDao.clearScenario(id);
    // The shared index is the scenario's ONLY persisted representation, so its
    // row must go with the build meta too — otherwise deleting a scenario would
    // leave its blob behind until some other scenario happens to rebuild.
    await ScenarioSharedIndexDao(db).gcStaleGenerations();
    return true;
  }

  // ── Scenario Sources ──

  Future<List<ScenarioSource>> getSources(String scenarioId) =>
      sourcesDao.getByScenario(scenarioId);

  Future<void> addSource({
    required String scenarioId,
    required String storageId,
    required String path,
    bool recursive = false,
    ScenarioSourceKind kind = ScenarioSourceKind.folder,
  }) async {
    await db.transaction(() async {
      final sortOrder = await sourcesDao.nextSortOrder(scenarioId);
      await sourcesDao.upsert(
        ScenarioSource(
          id: 0,
          scenarioId: scenarioId,
          storageId: storageId,
          path: path,
          recursive: recursive,
          sourceKind: kind,
          sortOrder: sortOrder,
          createdAt: DateTime.now(),
        ),
      );
    });
  }

  Future<void> removeSource(int sourceId) => sourcesDao.deleteSource(sourceId);

  Future<void> clearSources(String scenarioId) =>
      sourcesDao.deleteByScenario(scenarioId);

  /// Batch form of [addSource]: ONE transaction and ONE `nextSortOrder` read,
  /// so a drop of many folders never pays a DB round trip per folder.
  ///
  /// Specs that duplicate each other or an existing row (same storage +
  /// canonical path) collapse to one row, matching the table's
  /// UNIQUE(scenario_id, storage_id, path) constraint.
  ///
  /// Recursion is the only dimension the UNIQUE key lets vary: because the key
  /// is (scenario, storage, path), a folder re-added RECURSIVELY over a stored
  /// non-recursive row must PROMOTE that row instead of being silently dropped
  /// — otherwise the wider scope never takes effect (the append path relies on
  /// this, as it adds without clearing existing sources). A recursive row is
  /// never downgraded by a later non-recursive spec.
  Future<void> addSources({
    required String scenarioId,
    required List<
            ({
              String storageId,
              String path,
              bool recursive,
              ScenarioSourceKind kind
            })>
        specs,
  }) async {
    if (specs.isEmpty) return;
    await db.transaction(() async {
      // Collapse the batch first, recursive-wins, so within-batch duplicates
      // cannot later need an id-less upgrade.
      final merged = <String, ({
        String storageId,
        String path,
        bool recursive,
        ScenarioSourceKind kind
      })>{};
      for (final spec in specs) {
        final key = canonicalKey(spec.storageId, spec.path);
        final prior = merged[key];
        if (prior == null || (!prior.recursive && spec.recursive)) {
          merged[key] = spec;
        }
      }

      final existing = await sourcesDao.getByScenario(scenarioId);
      final storedByKey = <String, ScenarioSource>{
        for (final e in existing) canonicalKey(e.storageId, e.path): e,
      };
      var order = await sourcesDao.nextSortOrder(scenarioId);
      for (final spec in merged.values) {
        final key = canonicalKey(spec.storageId, spec.path);
        final stored = storedByKey[key];
        if (stored != null) {
          if (!stored.recursive && spec.recursive) {
            await sourcesDao.upsert(stored.copyWith(recursive: true));
          }
          continue;
        }
        await sourcesDao.upsert(
          ScenarioSource(
            id: 0,
            scenarioId: scenarioId,
            storageId: spec.storageId,
            path: spec.path,
            recursive: spec.recursive,
            sourceKind: spec.kind,
            sortOrder: order++,
            createdAt: DateTime.now(),
          ),
        );
      }
    });
  }

  /// Copies all sources from one scenario to another, preserving relative
  /// sortOrder (appends after the target's existing sources).
  ///
  /// Duplicate-tolerant: rows already present on the target AND rows that
  /// repeat within the source list (legacy dirty data) are skipped, so the
  /// copy never violates the table's UNIQUE(scenario_id, storage_id, path).
  ///
  /// The dedup key is canonical ([canonicalKey] over the DB path form): stored
  /// rows may hold legacy caller-slash-dependent paths that differ raw (e.g.
  /// `/a/b` vs `a/b`) yet canonicalize to the same value — exactly what the
  /// write path normalizes via [canonicalDbPath], so the DB enforces uniqueness
  /// on the canonical form. Comparing raw paths would let those collide on copy.
  Future<void> copySources({
    required String sourceScenarioId,
    required String targetScenarioId,
  }) async {
    await db.transaction(() async {
      final sources = await sourcesDao.getByScenario(sourceScenarioId);
      final existing = await sourcesDao.getByScenario(targetScenarioId);
      final seenKeys = {
        for (final e in existing) canonicalKey(e.storageId, e.path),
      };
      var order = await sourcesDao.nextSortOrder(targetScenarioId);
      for (final s in sources) {
        final key = canonicalKey(s.storageId, s.path);
        if (seenKeys.contains(key)) continue;
        seenKeys.add(key);
        await sourcesDao.upsert(s.copyWith(
          id: 0,
          scenarioId: targetScenarioId,
          sortOrder: order++,
        ));
      }
    });
  }

  /// Copies sources while skipping any source that already exists on the
  /// target (D7 append dedup). New sources are appended after the target's
  /// existing sources with continuing sortOrder.
  ///
  /// The dedup key is the canonical [canonicalKey] form (see [copySources]):
  /// the `scenario_sources` table's UNIQUE(scenario_id, storage_id, path)
  /// constraint is enforced on the canonical DB path, so raw legacy slash
  /// variants of the same folder must collapse to one key — within the source
  /// list itself (legacy dirty data) as well as against the target.
  Future<void> copySourcesDedup({
    required String sourceScenarioId,
    required String targetScenarioId,
  }) async {
    await db.transaction(() async {
      final sources = await sourcesDao.getByScenario(sourceScenarioId);
      final existing = await sourcesDao.getByScenario(targetScenarioId);
      final seenKeys = {
        for (final e in existing) canonicalKey(e.storageId, e.path),
      };
      var order = await sourcesDao.nextSortOrder(targetScenarioId);
      for (final s in sources) {
        final key = canonicalKey(s.storageId, s.path);
        if (seenKeys.contains(key)) continue;
        seenKeys.add(key);
        await sourcesDao.upsert(s.copyWith(
          id: 0,
          scenarioId: targetScenarioId,
          sortOrder: order++,
        ));
      }
    });
  }

  /// Heals the duplicate source rows of ONE scenario that canonicalize to the
  /// same `(storage_id, path)`. Same rule as [dedupeSources] but scoped to
  /// [scenarioId], so the scenario-source refresh can tidy a single scenario
  /// without touching unrelated rows.
  ///
  /// Returns the number of rows removed (0 when the scenario was compliant).
  Future<int> dedupeScenarioSources(String scenarioId) async {
    return db.transaction(() async {
      final all = await sourcesDao.getByScenario(scenarioId);
      final keepIds = <int>{};
      final seen = <String>{};
      for (final s in all) {
        if (seen.add(canonicalKey(s.storageId, s.path))) {
          keepIds.add(s.id);
        }
      }
      final deleteIds =
          all.map((s) => s.id).where((id) => !keepIds.contains(id)).toList();
      for (final id in deleteIds) {
        await sourcesDao.deleteSource(id);
      }
      return deleteIds.length;
    });
  }

  /// Heals legacy duplicate source rows that canonicalize to the same
  /// (scenario_id, storage_id, path) — including raw slash variants such as
  /// `/a/b` vs `a/b` that the UNIQUE constraint (enforced on the canonical DB
  /// path via [canonicalDbPath]) would reject on write. For each canonical
  /// group the lowest-id row survives and the rest are deleted. Idempotent and
  /// safe to run on every startup (a compliant table is unaffected).
  Future<void> dedupeSources() async {
    await db.transaction(() async {
      final all = await sourcesDao.getAll();
      final keepIds = <int>{};
      final seen = <String>{};
      for (final s in all) {
        final key = '${s.scenarioId}|${canonicalKey(s.storageId, s.path)}';
        if (seen.add(key)) {
          keepIds.add(s.id);
        }
      }
      final deleteIds =
          all.map((s) => s.id).where((id) => !keepIds.contains(id)).toList();
      for (final id in deleteIds) {
        await sourcesDao.deleteSource(id);
      }
    });
  }

  // ── Explicit Items ──

  Future<List<ScenarioExplicitItem>> getExplicitItems(String scenarioId) =>
      itemsDao.getByScenario(scenarioId);

  Future<void> addExplicitItem({
    required String scenarioId,
    required String storageId,
    required String path,
    String? batchId,
    int? mediaId,
    String? uiSortKey,
  }) async {
    final existing = await itemsDao.getByScenario(scenarioId);
    final maxAdd = existing
        .where((e) => e.batchId == batchId)
        .fold<int>(0, (max, e) => e.addOrder > max ? e.addOrder : max);
    return itemsDao.upsert(
      ScenarioExplicitItem(
        id: 0,
        scenarioId: scenarioId,
        batchId: batchId,
        storageId: storageId,
        path: path,
        mediaId: mediaId,
        addOrder: maxAdd + 1,
        uiSortKey: uiSortKey,
        createdAt: DateTime.now(),
      ),
    );
  }

  Future<void> removeExplicitItem(int itemId) => itemsDao.deleteItem(itemId);

  /// Batch form of [removeExplicitItem]: ONE transaction for the whole set, so
  /// a cleanup of N redundant additions never pays N autocommits (and an open
  /// queue sees a single definition change). Empty input is a no-op.
  Future<void> removeExplicitItems(Iterable<int> itemIds) async {
    final ids = itemIds.toList(growable: false);
    if (ids.isEmpty) return;
    await db.transaction(() => itemsDao.deleteItems(ids));
  }

  Future<void> clearExplicitItems(String scenarioId) =>
      itemsDao.deleteByScenario(scenarioId);

  /// Batch form of [addExplicitItem]: ONE transaction and ONE `getByScenario`
  /// read, so a drop of many files never pays an O(N) read per file (the
  /// per-file loop used to be O(N²) over the whole drop).
  ///
  /// `addOrder` continues per `batchId` exactly like [addExplicitItem]: the
  /// first new row of a batch takes the batch's current max + 1 and the rest
  /// follow in list order.
  Future<void> addExplicitItems({
    required String scenarioId,
    required List<
            ({
              String storageId,
              String path,
              String? batchId,
              int? mediaId,
              String? uiSortKey
            })>
        items,
  }) async {
    if (items.isEmpty) return;
    await db.transaction(() async {
      final existing = await itemsDao.getByScenario(scenarioId);
      final orderByBatch = <String?, int>{};
      final seen = <String>{};
      for (final e in existing) {
        final cur = orderByBatch[e.batchId] ?? 0;
        if (e.addOrder > cur) orderByBatch[e.batchId] = e.addOrder;
        seen.add(canonicalKey(e.storageId, e.path));
      }
      for (final it in items) {
        // The table's UNIQUE(scenario_id, storage_id, path) is NOT the PK, so
        // an insertOnConflictUpdate would throw on a repeat; collapse
        // duplicates (within the batch and against existing rows) instead.
        if (!seen.add(canonicalKey(it.storageId, it.path))) continue;
        final next = (orderByBatch[it.batchId] ?? 0) + 1;
        orderByBatch[it.batchId] = next;
        await itemsDao.upsert(
          ScenarioExplicitItem(
            id: 0,
            scenarioId: scenarioId,
            batchId: it.batchId,
            storageId: it.storageId,
            path: it.path,
            mediaId: it.mediaId,
            addOrder: next,
            uiSortKey: it.uiSortKey,
            createdAt: DateTime.now(),
          ),
        );
      }
    });
  }

  /// Copies all explicit items (preserving batchId/addOrder/uiSortKey).
  Future<void> copyExplicitItems({
    required String sourceScenarioId,
    required String targetScenarioId,
  }) async {
    final items = await itemsDao.getByScenario(sourceScenarioId);
    for (final item in items) {
      await itemsDao.upsert(item.copyWith(id: 0, scenarioId: targetScenarioId));
    }
  }

  // ── Exclude Rules (F1: logical uniqueness enforced here) ──

  Future<List<ScenarioExcludeRule>> getExcludeRules(String scenarioId) =>
      excludesDao.getByScenario(scenarioId);

  /// Adds or replaces a logically-equal exclude rule (F1).
  ///
  /// "Same logical rule" = same (scenarioId, scope, sourceId, kind, storageId,
  /// path) 6-tuple with NULL-equality on sourceId. [lifetime] is NOT part of the
  /// key — promoting temp→persistent replaces the rule.
  Future<void> addExcludeRule({
    required String scenarioId,
    required ScenarioExcludeRule rule,
  }) async {
    await db.transaction(() async {
      final existing = await excludesDao.findLogical(
        scenarioId: scenarioId,
        scope: rule.scope,
        sourceId: rule.sourceId,
        kind: rule.kind.name,
        storageId: rule.storageId,
        path: rule.path,
      );
      if (existing != null) {
        await excludesDao.deleteRule(existing.id);
      }
      await excludesDao.upsert(
        rule.copyWith(scenarioId: scenarioId, createdAt: DateTime.now()),
      );
    });
  }

  Future<void> removeExcludeRule(int ruleId) => excludesDao.deleteRule(ruleId);

  Future<void> clearExcludes(String scenarioId) =>
      excludesDao.deleteByScenario(scenarioId);

  /// Clears only temporary excludes (E1 — override clears everything).
  Future<void> clearTemporaryExcludes(String scenarioId) =>
      excludesDao.deleteTemporary(scenarioId);

  /// Copies only persistent excludes (A6/E1) from one scenario to another,
  /// via the F1 logical-uniqueness upsert.
  Future<void> copyPersistentExcludes({
    required String sourceScenarioId,
    required String targetScenarioId,
  }) async {
    final rules = await excludesDao.getByScenario(sourceScenarioId);
    for (final rule in rules) {
      if (rule.lifetime != ExcludeLifetime.persistent) continue;
      await addExcludeRule(
        scenarioId: targetScenarioId,
        rule: rule.copyWith(id: 0, scenarioId: targetScenarioId),
      );
    }
  }

  // ── Scenario Playback State ──

  Future<ScenarioState?> getState(String scenarioId) =>
      statesDao.getByScenario(scenarioId);

  Future<void> _ensureState(String scenarioId) async {
    if (await statesDao.getByScenario(scenarioId) == null) {
      await statesDao.upsert(ScenarioState(scenarioId: scenarioId));
    }
  }

  Future<void> updateState(ScenarioState state) => statesDao.upsert(state);

  Future<void> touchState(String scenarioId) async {
    final state = await statesDao.getByScenario(scenarioId);
    await statesDao.upsert(
      (state ?? ScenarioState(scenarioId: scenarioId))
          .copyWith(lastActiveAt: DateTime.now()),
    );
  }
}
