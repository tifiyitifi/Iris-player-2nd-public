import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_state.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/settings_transfer/engine/section_coder.dart';
import 'package:iris/features/settings_transfer/model/import_resolution.dart';
import 'package:iris/features/settings_transfer/model/transfer_item_result.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:uuid/uuid.dart';

class ScenarioCoder implements SectionCoder {
  @override
  String get sectionKey => 'scenarios';

  @override
  Future<Map<String, dynamic>?> encode() async {
    try {
      final repo = DbModule.scenarioRepo;
      final scenarios = await repo.getAllScenarios();
      final toExport =
          scenarios.where((s) => s.type == ScenarioKind.userSaved).toList();
      final items = <Map<String, dynamic>>[];
      // Counted so a scenario that could not be READ does not come back as
      // "the backup simply had none": `payload: []` alone reads as an empty
      // section. The `error` key is what `failedExportSections` turns into the
      // partial-export confirmation, while the good items still ride along.
      var failedScenarios = 0;
      for (final s in toExport) {
        try {
          final sources = await repo.getSources(s.id);
          final explicit = await repo.getExplicitItems(s.id);
          final excludes = await repo.getExcludeRules(s.id);
          final state = await repo.getState(s.id);
          items.add({
            'scenario': s.toJson(),
            'sources': [for (final e in sources) e.toJson()],
            'explicitItems': explicit.map((e) => e.toJson()).toList(),
            'excludes': excludes.map((e) => e.toJson()).toList(),
            'state': state?.toJson(),
          });
        } catch (_) {
          failedScenarios++;
          continue;
        }
      }
      return {
        'subVersion': 1,
        'payload': items,
        if (failedScenarios > 0)
          'error': 'failed to encode $failedScenarios scenario(s)',
      };
    } catch (e) {
      return {'subVersion': 1, 'payload': [], 'error': e.toString()};
    }
  }

  @override
  Future<List<TransferItemResult>> importSection(
    Map<String, dynamic>? payload, {
    required TransferResolution resolution,
    required bool skipErrors,
  }) async {
    if (resolution == TransferResolution.skip || payload == null) return [];
    final list = (payload['payload'] as List?) ?? [];
    final results = <TransferItemResult>[];
    if (list.isEmpty) {
      results.add(TransferItemResult(
          section: sectionKey, label: 'scenarios: empty', ok: true));
      return results;
    }
    final repo = DbModule.scenarioRepo;
    Map<String, Scenario> existingByName = {};
    try {
      final existing = await repo.getAllScenarios();
      // Overwrite matches by NAME, and only userSaved scenarios are exported.
      // Including the internal rows (Playing / Background / entry workspaces)
      // would let a saved scenario that happens to share their name hijack one
      // of them on import (updateScenario has no type guard).
      for (final s in existing) {
        if (s.type == ScenarioKind.userSaved) existingByName[s.name] = s;
      }
    } catch (_) {}

    for (final raw in list) {
      try {
        final m = (raw as Map).cast<String, dynamic>();
        final scenarioJson = (m['scenario'] as Map).cast<String, dynamic>();
        final name = scenarioJson['name'] as String? ?? 'Unnamed';
        final sources = (m['sources'] as List?) ?? [];
        final explicitItems = (m['explicitItems'] as List?) ?? [];
        final excludes = (m['excludes'] as List?) ?? [];
        final stateJson = m['state'] as Map<String, dynamic>?;

        // Assigned by the transaction body below (both branches set it before
        // returning); `late` keeps the analyzer happy without a dummy default.
        late String targetId;
        bool isExisting = false;
        // Counted so the report can say the import DROPPED something: a pre-v49
        // backup with tag sources used to come back with no sources and a plain
        // `ok`, which reads as "the backup had none".
        var droppedRetiredSources = 0;
        // Counted as well: a malformed explicit item is skipped in tolerant
        // mode, and the report must not look like the backup had none.
        var droppedInvalidItems = 0;
        // ONE transaction per scenario: the overwrite branch CLEARS the previous
        // sources / explicit items / excludes before rewriting them, so a failure
        // in between (a `skipErrors: false` abort thrown from an inner item loop)
        // used to leave the old definition destroyed and the new one half
        // written. Inside the transaction that abort rolls the whole scenario
        // back, and nothing changes for a failed item.
        await repo.inTransaction(() async {
          if (resolution == TransferResolution.overwrite &&
              existingByName.containsKey(name)) {
            final existing = existingByName[name]!;
            targetId = existing.id;
            isExisting = true;
            await repo.clearSources(targetId);
            await repo.clearExplicitItems(targetId);
            await repo.clearExcludes(targetId);
            // update scenario fields from imported json (keep id)
            //
            // A header that cannot be parsed or written must FAIL the scenario
            // (the outer catch reports it and, with `skipErrors: false`, stops
            // the import): the clears above already ran inside this transaction,
            // and swallowing the error used to write the content under the STALE
            // header and still report `ok` — a half-applied overwrite reported
            // as a success.
            final imported = Scenario.fromJson(scenarioJson);
            await repo.updateScenario(imported.copyWith(
              id: targetId,
              // An import may only ever write a SAVED scenario. The payload's
              // `type` is plain JSON in a file the user can edit, and
              // `updateScenario` is an UPSERT with no type guard: trusting it is
              // how a hand-edited export becomes a SECOND Playing/Background
              // row (after which `getByType`'s LIMIT 1 and the store's own
              // lookup can pick different rows) — and, on an overwrite, how an
              // existing saved scenario is silently retyped and disappears from
              // the saved list.
              type: ScenarioKind.userSaved,
              updatedAt: DateTime.now(),
            ));
          } else {
            String proposedId =
                scenarioJson['id'] as String? ?? const Uuid().v4();
            if (await repo.getScenario(proposedId) != null) {
              proposedId = const Uuid().v4();
            }
            targetId = proposedId;
            try {
              final imported = Scenario.fromJson(scenarioJson);
              // Same rule as the overwrite branch above: an import creates a
              // SAVED scenario, never an internal one.
              await repo.updateScenario(imported.copyWith(
                id: targetId,
                type: ScenarioKind.userSaved,
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
              ));
            } catch (_) {
              final created = await repo.createScenario(name: name);
              targetId = created.id;
            }
          }

          final seenSourceKeys = <String>{};
          for (final sRaw in sources) {
            try {
              final sm = (sRaw as Map).cast<String, dynamic>();
              // The v49 tag-source retirement: a pre-v49 export may still carry a
              // `tag:<id>` source (the reserved tag used ''). It has no
              // (storageId, path) identity — the tag membership is now a VIEW
              // over a scenario, never a source row. Importing it as a folder
              // would rebuild the exact row v49 deleted, pointing at a storage
              // that does not exist. Drop it outright.
              final rawKind = sm['sourceKind'];
              if (rawKind is String && _retiredSourceKinds.contains(rawKind)) {
                droppedRetiredSources++;
                continue;
              }
              // Round-trip the source's (storageId, path, recursive, kind). An
              // older export has no `sourceKind`; folder is the default.
              final kind = _sourceKindOf(rawKind);
              final storageId = sm['storageId'] as String? ?? '';
              // Belt-and-braces: a hand-edited export may name a real folder kind
              // but still point at the retired `tag:` identity.
              if (storageId.startsWith('tag:')) {
                droppedRetiredSources++;
                continue;
              }
              final path = sm['path'] as String? ?? '/';
              // A hand-edited / foreign export may repeat a source the table's
              // UNIQUE(scenario_id, storage_id, path) would reject. Drop the
              // repeat instead of letting the constraint abort the scenario
              // (skipErrors=false) or silently lose the row (skipErrors=true).
              if (!seenSourceKeys.add(ScenarioRepository.sourceIdentityKey(
                storageId: storageId,
                path: path,
              ))) {
                continue;
              }
              await repo.addSource(
                scenarioId: targetId,
                storageId: storageId,
                path: path,
                recursive: sm['recursive'] as bool? ?? false,
                kind: kind,
              );
            } catch (e) {
              if (!skipErrors) throw e;
            }
          }
          // Explicit items land through the BATCH writer: it preserves batchId /
          // mediaId / uiSortKey and collapses a repeat against the table's
          // UNIQUE(scenario_id, storage_id, path). The per-item
          // `addExplicitItem` loop dropped those fields AND let one repeated row
          // throw, which with skipErrors=false aborted the whole file — the
          // remaining scenarios were silently lost. `addOrder` is re-derived per
          // batch (the writer's own contract), so the visual order is preserved.
          final explicitBatch = <({
            String storageId,
            String path,
            String? batchId,
            int? mediaId,
            String? uiSortKey
          })>[];
          for (final eRaw in explicitItems) {
            // One malformed item (a non-map, or a field of the wrong JSON type)
            // must not cost the WHOLE scenario: this loop used to sit outside
            // every try, so a single bad row aborted the transaction under
            // `skipErrors: true` as well. Tolerant mode skips the row and
            // reports it; strict mode still aborts (the caller asked for that).
            try {
              final em = (eRaw as Map).cast<String, dynamic>();
              explicitBatch.add((
                storageId: em['storageId'] as String? ?? '',
                path: em['path'] as String? ?? '',
                batchId: em['batchId'] as String?,
                mediaId: em['mediaId'] as int?,
                uiSortKey: em['uiSortKey'] as String?,
              ));
            } catch (e) {
              if (!skipErrors) rethrow;
              droppedInvalidItems++;
            }
          }
          try {
            await repo.addExplicitItems(
              scenarioId: targetId,
              items: explicitBatch,
            );
          } catch (e) {
            if (!skipErrors) throw e;
            droppedInvalidItems += explicitBatch.length;
          }
          for (final exRaw in excludes) {
            try {
              final exm = (exRaw as Map).cast<String, dynamic>();
              final rule = ScenarioExcludeRule.fromJson(exm);
              await repo.addExcludeRule(scenarioId: targetId, rule: rule);
            } catch (e) {
              if (!skipErrors) throw e;
            }
          }
          if (stateJson != null) {
            try {
              final st = ScenarioState.fromJson(stateJson);
              await repo.updateState(st.copyWith(scenarioId: targetId));
            } catch (_) {}
          }
        });

        results.add(TransferItemResult(
          section: sectionKey,
          label: name,
          ok: true,
          // Reported on the row so a dropped source/item is visible in the
          // transfer report instead of looking like an empty scenario.
          error: () {
            final notes = <String>[
              if (droppedRetiredSources > 0)
                'skipped $droppedRetiredSources retired tag source(s)',
              if (droppedInvalidItems > 0)
                'skipped $droppedInvalidItems malformed explicit item(s)',
            ];
            return notes.isEmpty ? null : notes.join('; ');
          }(),
        ));
        if (isExisting) {
          final updated = await repo.getScenario(targetId);
          if (updated != null) existingByName[name] = updated;
        } else {
          try {
            final created = await repo.getScenario(targetId);
            if (created != null) existingByName[name] = created;
          } catch (_) {}
        }
      } catch (e) {
        final label =
            (raw as Map)['scenario']?['name']?.toString() ?? raw.toString();
        results.add(TransferItemResult(
            section: sectionKey, label: label, ok: false, error: e.toString()));
        if (!skipErrors) return results;
      }
    }
    return results;
  }

  /// Scenario source kinds that a pre-v49 export could carry but the app has
  /// since retired. Their rows are dropped on import, never coerced to folder.
  static const Set<String> _retiredSourceKinds = {'tag'};

  /// Maps an exported `sourceKind` enum name back to its value. An older export
  /// (no key) or an unknown name falls back to [ScenarioSourceKind.folder],
  /// which is also the pre-tag default. A retired kind never reaches here — see
  /// [_retiredSourceKinds], checked (and dropped) by the caller.
  static ScenarioSourceKind _sourceKindOf(Object? raw) {
    if (raw is String) {
      for (final k in ScenarioSourceKind.values) {
        if (k.name == raw) return k;
      }
    }
    return ScenarioSourceKind.folder;
  }
}
