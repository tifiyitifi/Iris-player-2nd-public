import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/search/model/search_context.dart';
import 'package:iris/features/media_library/search/model/search_path_match.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_explicit_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';

/// Redundancy rule for scenario explicit (manual) additions.
///
/// An explicit item is REDUNDANT when a DIRECTORY source of the same scenario
/// already covers its file. The match reuses [sourceCovers] — the exact
/// predicate the search DB uses to decide "in scope" (§5.1.2) — so the queue
/// cleanup and the search surface can never disagree on coverage:
/// - recursive whole-storage source (empty path) → every file of that storage;
/// - non-recursive whole-storage source → storage-root files only;
/// - recursive directory → the directory and anything beneath it;
/// - non-recursive directory → direct children only.
///
/// A folder source ALWAYS maps to [MediaSourceKind.directory], even when its
/// path is empty: the `directory` predicate already carries the recursion
/// dimension, whereas [MediaSourceKind.storage] means "the entire storage"
/// unconditionally and would wrongly treat a non-recursive root source as
/// covering every subdirectory — deleting explicit items the queue still needs
/// (playback's `FolderSourceProvider` resolves a non-recursive root source to
/// the root's direct children only).
///
/// Single-FILE sources are deliberately EXCLUDED: a manual addition duplicating
/// a single-file source is not what this cleanup targets, and treating it as
/// coverage would silently delete an addition the user still needs once the
/// file source is removed.
bool scenarioSourceCoversFile(
  ScenarioSource source,
  String storageId,
  String path,
) {
  if (source.sourceKind != ScenarioSourceKind.folder) return false;
  return sourceCovers(
    SearchSource(
      storageId: source.storageId,
      path: source.path.isEmpty ? null : source.path,
      kind: MediaSourceKind.directory,
      recursive: source.recursive,
      scenarioSourceId: source.id,
    ),
    storageId,
    path,
  );
}

/// Whether [item] is already covered by any directory/whole-storage source in
/// [sources].
bool isRedundantExplicitItem(
  ScenarioExplicitItem item,
  List<ScenarioSource> sources,
) =>
    sources.any((s) => scenarioSourceCoversFile(s, item.storageId, item.path));

/// The subset of [items] that is redundant against [sources], preserving
/// [items] order. Pure and store-free so the cleanup rule is unit-testable.
List<ScenarioExplicitItem> redundantExplicitItems({
  required List<ScenarioSource> sources,
  required List<ScenarioExplicitItem> items,
}) =>
    [
      for (final item in items)
        if (isRedundantExplicitItem(item, sources)) item,
    ];
