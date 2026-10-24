import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_sort_spec.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_state.dart';
import 'package:iris/models/db/db_module.dart';

/// The scenario mutation layer (A5): ALL definition/state writes go through
/// these commands — never `scenario.sources.add()` from UI/actions.
///
/// Behavior follows the D2 matrix (E1/F2):
/// - Override clears ALL workspace definition + state, no exclusions survive,
///   originScenarioId is replaced with the overridden source (F2).
/// - Append merges, keeps the workspace's excludes, keeps originScenarioId (F2).
/// - Save As copies Definition + Playback State; temporary excludes ignored.
/// - Sync back is disabled when originScenarioId == null (E2).
///
/// Save-dialog targets (workspace→target, D5/D6):
/// - overrideTarget replaces the target from the workspace (config + state).
/// - appendTarget merges the workspace into the target (source dedup).
class ScenarioCommands {
  const ScenarioCommands._();

  /// Override the SystemPlaying workspace with [source]'s Definition +
  /// Playback State (D2/E1/F2).
  ///
  /// [workspace] is the `systemPlaying` [Scenario] row. When [source] is null
  /// (manual scope, e.g. play a folder), the workspace is simply reset.
  /// [importPersistentExcludes] lets the caller choose whether the source's
  /// persistent excludes are imported (Load-row "Replace/Merge by user choice").
  ///
  /// [copyState] = false installs the Definition only. Used when minting a
  /// window-private workspace for an independent entry: sources/sort/excludes
  /// are shared intent, while the queue position belongs to the window that is
  /// about to play (a fresh row must not resume another window's item).
  static Future<void> override({
    required Scenario workspace,
    Scenario? source,
    bool importPersistentExcludes = true,
    bool copyState = true,
    ScenarioRepository? repo,
  }) async {
    final r = repo ?? DbModule.scenarioRepo;
    final wsId = workspace.id;

    // Run the whole clear+copy in one transaction so a mid-way failure rolls
    // back instead of leaving the workspace half-cleared/corrupted.
    await r.db.transaction(() async {
      // E1: clear ALL definition + playback state.
      await r.clearSources(wsId);
      await r.clearExplicitItems(wsId);
      await r.clearExcludes(wsId);
      await r.updateState(ScenarioState(scenarioId: wsId));

      if (source == null) return;

      // Install the source Definition.
      await r.copySources(sourceScenarioId: source.id, targetScenarioId: wsId);
      await r.copyExplicitItems(
          sourceScenarioId: source.id, targetScenarioId: wsId);
      if (importPersistentExcludes) {
        await r.copyPersistentExcludes(
            sourceScenarioId: source.id, targetScenarioId: wsId);
      }

      // Copy Definition config (sorting / shuffle config / duplicate / repeat).
      await r.updateScenario(workspace.copyWith(
        sortField: source.sortField,
        sortDirection: source.sortDirection,
        originalSortField: source.originalSortField ?? source.sortField,
        order: source.order,
        duplicatePolicy: source.duplicatePolicy,
        repeatMode: source.repeatMode,
        sourceInternalFirst: source.sourceInternalFirst,
      ));

      // F2: origin = source; copy Playback State (D1).
      if (!copyState) return;
      final sourceState = await r.getState(source.id);
      await r.updateState(
        (sourceState ?? ScenarioState(scenarioId: wsId)).copyWith(
          scenarioId: wsId,
          originScenarioId: source.id,
          importedAt: DateTime.now(),
          importVersion: source.version,
        ),
      );
    });
  }

  /// Applies a full sort view [spec] to [workspace]'s Definition + Playback
  /// State (the Preview-tap commit path). Records
  /// `originalSortField = spec.sortField` so the order menu's "Original"
  /// restores the newly applied sort rule. When shuffled, writes the spec's
  /// seed and bumps `shuffleVersion`; otherwise clears the seed. Repeat mode
  /// and origin markers are left untouched.
  static Future<void> applySortConfig({
    required Scenario workspace,
    required ScenarioSortSpec spec,
    ScenarioRepository? repo,
  }) async {
    final r = repo ?? DbModule.scenarioRepo;
    final wsId = workspace.id;
    await r.updateScenario(workspace.copyWith(
      sortField: spec.sortField,
      sortDirection: spec.sortDirection,
      order: spec.order,
      duplicatePolicy: spec.duplicatePolicy,
      sourceInternalFirst: spec.sourceInternalFirst,
      originalSortField: spec.sortField,
    ));
    final s = await r.getState(wsId);
    await r.updateState(
      (s ?? ScenarioState(scenarioId: wsId)).copyWith(
        shuffleSeed: spec.shuffled ? spec.shuffleSeed : null,
        shuffleVersion: spec.shuffled
            ? (s?.shuffleVersion ?? 0) + 1
            : (s?.shuffleVersion ?? 0),
      ),
    );
  }

  /// Append [source]'s Definition into the SystemPlaying workspace (D2/F2).
  ///
  /// Sources/items are merged (appended at the end); workspace temporary AND
  /// persistent excludes are kept; originScenarioId is KEPT (F2).
  static Future<void> append({
    required Scenario workspace,
    required Scenario source,
    bool importPersistentExcludes = true,
    ScenarioRepository? repo,
  }) async {
    final r = repo ?? DbModule.scenarioRepo;
    final wsId = workspace.id;

    await r.copySources(sourceScenarioId: source.id, targetScenarioId: wsId);
    await r.copyExplicitItems(
        sourceScenarioId: source.id, targetScenarioId: wsId);
    if (importPersistentExcludes) {
      await r.copyPersistentExcludes(
          sourceScenarioId: source.id, targetScenarioId: wsId);
    }

    // F2: originScenarioId unchanged; only refresh the import marker.
    final state = await r.getState(wsId);
    await r.updateState(
      (state ?? ScenarioState(scenarioId: wsId)).copyWith(
        importedAt: DateTime.now(),
        importVersion: source.version,
      ),
    );
  }

  /// Save the SystemPlaying workspace as a new userSaved Scenario (D1/D2).
  ///
  /// Copies Definition (sources + explicit items + persistent excludes only —
  /// temporary excludes are ignored) and Playback State. Runtime caches and UI
  /// temp state are never copied. Returns the created Scenario (version = 0).
  static Future<Scenario> saveAs({
    required Scenario workspace,
    String? name,
    String? description,
    ScenarioRepository? repo,
  }) async {
    final r = repo ?? DbModule.scenarioRepo;
    final scenario = await r.createScenario(
      name: name ?? _defaultName(),
      description: description,
    );

    // Copy the full Definition config so the saved scenario preserves the
    // workspace's sort / Original (first-add rule) / shuffle / dedup / repeat
    // preference (D1). createScenario leaves originalSortField null, so this is
    // what keeps "Original" meaningful on the saved copy.
    await r.updateScenario(scenario.copyWith(
      sortField: workspace.sortField,
      sortDirection: workspace.sortDirection,
      originalSortField: workspace.originalSortField,
      order: workspace.order,
      duplicatePolicy: workspace.duplicatePolicy,
      repeatMode: workspace.repeatMode,
      sourceInternalFirst: workspace.sourceInternalFirst,
    ));

    await r.copySources(
        sourceScenarioId: workspace.id, targetScenarioId: scenario.id);
    await r.copyExplicitItems(
        sourceScenarioId: workspace.id, targetScenarioId: scenario.id);
    await r.copyPersistentExcludes(
        sourceScenarioId: workspace.id, targetScenarioId: scenario.id);

    final wsState = await r.getState(workspace.id);
    await r.updateState(
      (wsState ?? ScenarioState(scenarioId: scenario.id)).copyWith(
        scenarioId: scenario.id,
        originScenarioId: null,
        importedAt: null,
        importVersion: null,
      ),
    );
    return scenario;
  }

  /// Sync the SystemPlaying workspace back to its origin (E2/A6).
  ///
  /// Disabled (returns false) when `originScenarioId == null`. Temporary rules
  /// never sync; the origin's version is bumped.
  static Future<bool> syncBack({
    required Scenario workspace,
    ScenarioRepository? repo,
  }) async {
    final r = repo ?? DbModule.scenarioRepo;
    final wsId = workspace.id;

    final state = await r.getState(wsId);
    final originId = state?.originScenarioId;
    if (originId == null) return false; // E2

    final origin = await r.getScenario(originId);
    if (origin == null) return false;

    await r.clearSources(originId);
    await r.clearExplicitItems(originId);
    await r.clearExcludes(originId);
    await r.copySources(sourceScenarioId: wsId, targetScenarioId: originId);
    await r.copyExplicitItems(
        sourceScenarioId: wsId, targetScenarioId: originId);
    await r.copyPersistentExcludes(
        sourceScenarioId: wsId, targetScenarioId: originId);

    await r.updateState(
      (state ?? ScenarioState(scenarioId: originId)).copyWith(
        scenarioId: originId,
        originScenarioId: null,
        importedAt: null,
        importVersion: null,
      ),
    );
    await r.bumpVersion(originId);
    return true;
  }

  /// Override the [target] userSaved scenario from the SystemPlaying workspace
  /// (D5, save-dialog "Override it"): the workspace's Definition (sources +
  /// explicit items + persistent excludes + full definition config) and
  /// Playback State replace the target's, target origin/imported markers are
  /// cleared (mirrors [saveAs]), the description is updated and version bumped.
  /// Temporary excludes are never written.
  static Future<void> overrideTarget({
    required Scenario workspace,
    required String targetScenarioId,
    String? description,
    ScenarioRepository? repo,
  }) async {
    final r = repo ?? DbModule.scenarioRepo;
    final target = await r.getScenario(targetScenarioId);
    if (target == null) return;

    // E1-like: replace the target's Definition + Playback State.
    await r.clearSources(targetScenarioId);
    await r.clearExplicitItems(targetScenarioId);
    await r.clearExcludes(targetScenarioId);

    await r.copySources(sourceScenarioId: workspace.id, targetScenarioId: targetScenarioId);
    await r.copyExplicitItems(
        sourceScenarioId: workspace.id, targetScenarioId: targetScenarioId);
    await r.copyPersistentExcludes(
        sourceScenarioId: workspace.id, targetScenarioId: targetScenarioId);

    // Copy the full Definition config, plus the new description.
    await r.updateScenario(target.copyWith(
      sortField: workspace.sortField,
      sortDirection: workspace.sortDirection,
      originalSortField: workspace.originalSortField ?? workspace.sortField,
      order: workspace.order,
      duplicatePolicy: workspace.duplicatePolicy,
      repeatMode: workspace.repeatMode,
      sourceInternalFirst: workspace.sourceInternalFirst,
      description: description,
    ));

    // Copy Playback State from the workspace; clear origin/imported markers
    // (like saveAs).
    final wsState = await r.getState(workspace.id);
    await r.updateState(
      (wsState ?? ScenarioState(scenarioId: targetScenarioId)).copyWith(
        scenarioId: targetScenarioId,
        originScenarioId: null,
        importedAt: null,
        importVersion: null,
      ),
    );
    await r.bumpVersion(targetScenarioId);
  }

  /// Append the SystemPlaying workspace's content into the [target] userSaved
  /// scenario (D6/D7, save-dialog "Append to it"): sources are merged with
  /// (storageId, path, recursive) dedup, explicit items and persistent excludes
  /// are copied too, and the description is updated. The target's Definition
  /// config and ScenarioState (incl. origin) are left untouched. Version bumps.
  static Future<void> appendTarget({
    required Scenario workspace,
    required String targetScenarioId,
    String? description,
    ScenarioRepository? repo,
  }) async {
    final r = repo ?? DbModule.scenarioRepo;
    final target = await r.getScenario(targetScenarioId);
    if (target == null) return;

    await r.copySourcesDedup(
        sourceScenarioId: workspace.id, targetScenarioId: targetScenarioId);
    await r.copyExplicitItems(
        sourceScenarioId: workspace.id, targetScenarioId: targetScenarioId);
    await r.copyPersistentExcludes(
        sourceScenarioId: workspace.id, targetScenarioId: targetScenarioId);

    if (description != null) {
      await r.updateScenario(target.copyWith(description: description));
    }
    await r.bumpVersion(targetScenarioId);
  }

  /// Delete a userSaved Scenario and all its owned records (matrix: Delete × 4).
  /// The systemPlaying row cannot be deleted.
  static Future<bool> delete({required String scenarioId}) =>
      DbModule.scenarioRepo.deleteScenario(scenarioId);

  static String _defaultName() {
    final now = DateTime.now();
    final stamp = '${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}:${_two(now.minute)}';
    return 'Scenario $stamp';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}
