import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_shared_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_explicit_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source_spec.dart';
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

  /// Runs [body] in ONE database transaction.
  ///
  /// The transfer importer needs this: an overwrite CLEARS a scenario's sources /
  /// explicit items / excludes before rewriting them, and a failure in between
  /// (a `skipErrors: false` abort) used to leave the previous definition
  /// destroyed and the new one half-written. Inside a transaction the rollback
  /// restores the old definition, so a failed import changes nothing.
  ///
  /// Nested calls (the batch writers own `db.transaction` too) join this one.
  Future<T> inTransaction<T>(Future<T> Function() body) => db.transaction(body);

  /// Deletes every record [id] OWNS: its definition rows (sources / explicit
  /// items / excludes), its playback state, the scenario row itself and the
  /// persisted DERIVED queue index that is keyed by the same id.
  ///
  /// ONE transaction: the definition rows and the derived index belong to one
  /// id, so a failure in between leaves a generation no scenario can ever
  /// address, read or evict again — or, on a revived id (a settings-transfer
  /// re-import keeps the exported id), a stale queue serving the OLD definition.
  Future<void> _purgeScenarioRecords(String id) async {
    await db.transaction(() async {
      await sourcesDao.deleteByScenario(id);
      await itemsDao.deleteByScenario(id);
      await excludesDao.deleteByScenario(id);
      await statesDao.deleteByScenario(id);
      await scenariosDao.deleteScenario(id);
      // The derived index is keyed by a scenario id that no longer exists, so
      // nothing would ever read or evict it again — it dies WITH the row.
      await ScenarioQueueIndexDao(db).clearScenario(id);
      // The shared index is the scenario's ONLY persisted representation, so its
      // blob must go with the build meta too — otherwise deleting a scenario
      // would leave its blob behind until some other scenario happens to rebuild.
      await ScenarioSharedIndexDao(db).gcStaleGenerations();
    });
  }

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
  Future<void> deleteEntryWorkspace(String id) => _purgeScenarioRecords(id);

  /// The single 副音 (background) workspace row, if it already exists.
  Future<Scenario?> getBackgroundWorkspace() =>
      scenariosDao.getByType(ScenarioKind.background);

  /// Ensures the single 副音 workspace row exists (idempotent). Like
  /// [ensureSystemPlayingScenario] it is an internal kind: never shown in the
  /// saved-scenario list, never deleted through the scenario UI. It carries no
  /// definition of its own — 副音 plays the reserved 「副音备选」tag's view and
  /// the row is only the per-entry position/repeat state container.
  Future<Scenario> ensureBackgroundWorkspace() async {
    final existing = await scenariosDao.getByType(ScenarioKind.background);
    if (existing != null) return existing;

    final now = DateTime.now();
    final scenario = Scenario(
      id: const Uuid().v4(),
      name: 'Background',
      type: ScenarioKind.background,
      version: null,
      // 副音 loops by default (the scenario owns repeat/shuffle, so the default
      // lives here rather than on the bg store's prefs).
      repeatMode: Repeat.all,
      createdAt: now,
      updatedAt: now,
    );
    await scenariosDao.upsert(scenario);
    await _ensureState(scenario.id);
    areaKeyLog.i('Created background workspace: ${scenario.id}');
    return scenario;
  }

  /// Creates a fresh, dedicated 副音 workspace for ONE independent app entry
  /// ([ScenarioKind.entryBackground]). Unlike [ensureBackgroundWorkspace] there
  /// can be many of these (one per independent entry), so it always creates a
  /// new row; the owning entry persists the id and reuses it afterwards —
  /// mirroring [createEntryWorkspace].
  Future<Scenario> createEntryBackgroundWorkspace() async {
    final now = DateTime.now();
    final scenario = Scenario(
      id: const Uuid().v4(),
      name: 'Entry background',
      type: ScenarioKind.entryBackground,
      version: null,
      // Same default as the single background workspace (see there).
      repeatMode: Repeat.all,
      createdAt: now,
      updatedAt: now,
    );
    await scenariosDao.upsert(scenario);
    await _ensureState(scenario.id);
    areaKeyLog.i('Created entry background workspace: ${scenario.id}');
    return scenario;
  }

  /// Removes an entry's 副音 workspace and every record it owns. Mirrors
  /// [deleteEntryWorkspace]: bypasses the userSaved guard, dies with its entry.
  Future<void> deleteEntryBackgroundWorkspace(String id) =>
      _purgeScenarioRecords(id);

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

    await _purgeScenarioRecords(id);
    return true;
  }

  // ── Scenario Sources ──

  Future<List<ScenarioSource>> getSources(String scenarioId) =>
      sourcesDao.getByScenario(scenarioId);

  /// The `(storageId, path)` a prospective source row is stored under.
  ///
  /// A source is path-based only: a tag membership is a VIEW over a scenario
  /// (`TagViewResolver`), never a source row, so there is no sentinel identity
  /// to encode here.
  static ({String storageId, String path}) _storedIdentity({
    required String storageId,
    required String path,
  }) =>
      (storageId: storageId, path: path);

  /// Canonical identity key of a prospective source row — the same key the
  /// table's UNIQUE(scenario_id, storage_id, path) is enforced on. Import uses
  /// it to drop a duplicate a hand-edited / foreign export may repeat, instead
  /// of letting the constraint reject the row (or abort the whole scenario on
  /// `skipErrors: false`).
  static String sourceIdentityKey({
    required String storageId,
    required String path,
  }) =>
      canonicalKey(storageId, path);

  /// Adds one source, idempotent on the table's business key
  /// UNIQUE(scenario_id, storage_id, path).
  ///
  /// [sourcesDao.upsert] (`insertOnConflictUpdate`) only resolves PRIMARY-KEY
  /// conflicts, so a duplicate row would THROW on the business key instead of
  /// collapsing. Re-adding an already-stored source therefore converges on the
  /// existing row (promoting it to recursive when the new spec is wider, exactly
  /// like [addSources]) rather than throwing.
  Future<void> addSource({
    required String scenarioId,
    required String storageId,
    required String path,
    bool recursive = false,
    ScenarioSourceKind kind = ScenarioSourceKind.folder,
  }) async {
    final id = _storedIdentity(storageId: storageId, path: path);
    await db.transaction(() async {
      final existing = await sourcesDao.getByScenario(scenarioId);
      final key = canonicalKey(id.storageId, id.path);
      ScenarioSource? stored;
      for (final e in existing) {
        if (canonicalKey(e.storageId, e.path) == key) {
          stored = e;
          break;
        }
      }
      if (stored != null) {
        // Recursion is the only dimension the UNIQUE key lets vary: promote a
        // stored non-recursive row instead of dropping the wider scope.
        if (!stored.recursive && recursive) {
          await sourcesDao.upsert(stored.copyWith(recursive: true));
        }
        return;
      }
      final sortOrder = await sourcesDao.nextSortOrder(scenarioId);
      await sourcesDao.upsert(
        ScenarioSource(
          id: 0,
          scenarioId: scenarioId,
          storageId: id.storageId,
          path: id.path,
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
    required List<ScenarioSourceSpec> specs,
  }) async {
    if (specs.isEmpty) return;
    await db.transaction(() async {
      String keyOf(ScenarioSourceSpec spec) => sourceIdentityKey(
            storageId: spec.storageId,
            path: spec.path,
          );

      // Collapse the batch first, recursive-wins, so within-batch duplicates
      // cannot later need an id-less upgrade.
      final merged = <String, ScenarioSourceSpec>{};
      for (final spec in specs) {
        final key = keyOf(spec);
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
        final key = keyOf(spec);
        final stored = storedByKey[key];
        if (stored != null) {
          if (!stored.recursive && spec.recursive) {
            await sourcesDao.upsert(stored.copyWith(recursive: true));
          }
          continue;
        }
        final id = _storedIdentity(
          storageId: spec.storageId,
          path: spec.path,
        );
        await sourcesDao.upsert(
          ScenarioSource(
            id: 0,
            scenarioId: scenarioId,
            storageId: id.storageId,
            path: id.path,
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
      final keep = <String, ScenarioSource>{};
      final promoted = <ScenarioSource>[];
      for (final s in all) {
        final key = canonicalKey(s.storageId, s.path);
        final prior = keep[key];
        if (prior == null) {
          keep[key] = s;
          continue;
        }
        // Recursion is a SCOPE, not a detail: a stored non-recursive row next
        // to a recursive duplicate must be widened before the duplicate is
        // deleted, or healing silently narrows the scenario (the same rule
        // [addSources] applies within a batch).
        if (!prior.recursive && s.recursive) {
          final widened = prior.copyWith(recursive: true);
          keep[key] = widened;
          promoted.add(widened);
        }
      }
      for (final s in promoted) {
        await sourcesDao.upsert(s);
      }
      final keepIds = keep.values.map((s) => s.id).toSet();
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
  /// group the lowest-id row survives and the rest are deleted. A surviving row
  /// is first WIDENED to recursive when any duplicate was recursive: recursion
  /// is part of the source's meaning, so dropping the recursive copy would
  /// silently narrow the scenario on the next launch. Idempotent and safe to run
  /// on every startup (a compliant table is unaffected).
  Future<void> dedupeSources() async {
    await db.transaction(() async {
      final all = await sourcesDao.getAll();
      final keep = <String, ScenarioSource>{};
      final promoted = <ScenarioSource>[];
      for (final s in all) {
        final key = '${s.scenarioId}|${canonicalKey(s.storageId, s.path)}';
        final prior = keep[key];
        if (prior == null) {
          keep[key] = s;
          continue;
        }
        if (!prior.recursive && s.recursive) {
          final widened = prior.copyWith(recursive: true);
          keep[key] = widened;
          promoted.add(widened);
        }
      }
      for (final s in promoted) {
        await sourcesDao.upsert(s);
      }
      final keepIds = keep.values.map((s) => s.id).toSet();
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
    // The single-add entry point has to honour the same idempotency the batch
    // form enforces: the table's UNIQUE(scenario_id, storage_id, path) is NOT
    // the PK, so an insertOnConflictUpdate of an already-present item throws
    // instead of being a no-op (see [addExplicitItems]).
    final key = canonicalKey(storageId, path);
    if (existing.any((e) => canonicalKey(e.storageId, e.path) == key)) return;
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
  ///
  /// Duplicate-tolerant, exactly like [copySources]/[addExplicitItems]: the
  /// table's UNIQUE(scenario_id, storage_id, path) is NOT the PK, so an
  /// `insertOnConflictUpdate` of an item the target already carries THROWS
  /// instead of being a no-op (see [addExplicitItems]). The append/merge paths
  /// (`ScenarioCommands.append`, `appendTarget`) do NOT clear the target first,
  /// so a file present on both sides used to abort the whole command on its
  /// first overlap. Rows already on the target AND legacy rows that repeat
  /// within the source list collapse onto the canonical [canonicalKey] form —
  /// the same key the table's constraint is enforced on (see [copySources]).
  Future<void> copyExplicitItems({
    required String sourceScenarioId,
    required String targetScenarioId,
  }) async {
    await db.transaction(() async {
      final items = await itemsDao.getByScenario(sourceScenarioId);
      final existing = await itemsDao.getByScenario(targetScenarioId);
      final seen = {
        for (final e in existing) canonicalKey(e.storageId, e.path),
      };
      for (final item in items) {
        if (!seen.add(canonicalKey(item.storageId, item.path))) continue;
        await itemsDao.upsert(item.copyWith(id: 0, scenarioId: targetScenarioId));
      }
    });
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
      // `id` MUST be zeroed. Logical uniqueness is the 6-tuple above, never the
      // primary key, and `excludesDao.upsert` is `insertOnConflictUpdate` whose
      // default conflict target IS the PK. A rule carrying the EXPORTING
      // database's id (settings-transfer import — the coder serializes the
      // whole rule) collides with an unrelated row here and the upsert silently
      // rewrites that row's scenarioId/fields, i.e. hijacks another scenario's
      // exclude. Every in-app caller already passes `id: 0`.
      await excludesDao.upsert(
        rule.copyWith(
          id: 0,
          scenarioId: scenarioId,
          createdAt: DateTime.now(),
        ),
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
