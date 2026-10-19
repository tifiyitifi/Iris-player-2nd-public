import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_query.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_result.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/meta_settings/engine/browse_scope_snapshot.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/utils/path_conv.dart';

/// Abstraction over how a [ScenarioSource] resolves into playable media.
///
/// The resolver must NOT hard-code around one SQL strategy, and must NOT
/// understand every source type. Future providers implement this abstraction.
/// (A tag membership is NOT a provider — it is a VIEW over a scenario, resolved
/// by `TagViewResolver`.)
abstract class ScenarioSourceProvider {
  ScenarioSourceKind get kind;

  /// Total playable media count this source resolves to.
  Future<int> count(ScenarioSource source, MediaNodeRepository nodeRepo);

  /// Fetches a window of media for [source].
  Future<List<MediaNode>> fetch(
    ScenarioSource source,
    MediaNodeRepository nodeRepo, {
    required int offset,
    required int count,
    required ScenarioSortField sortField,
    required SortDirection sortDirection,

    /// 同目录连续 (pathGroupFirst): group same-parent files into contiguous
    /// blocks inside the source (ORDER BY parentPath, sortField, name). Ignored
    /// by single-file providers.
    required bool sourceInternalFirst,
  });
}

/// Resolves path/folder based [ScenarioSource]s against the media database.
///
/// It only queries the media database — it never scans the filesystem.
class FolderSourceProvider implements ScenarioSourceProvider {
  /// Browse-media-scope snapshot resolved at query time (defaults to the
  /// global funnel). Injectable so store-free test environments can pin the
  /// legacy playable-only semantics without an initialized AppStore.
  final List<MediaType>? Function() scopedMediaTypes;

  const FolderSourceProvider({
    this.scopedMediaTypes = currentBrowseScopeMediaTypes,
  });

  @override
  ScenarioSourceKind get kind => ScenarioSourceKind.folder;

  @override
  Future<int> count(ScenarioSource source, MediaNodeRepository nodeRepo) async {
    final result = await _query(source, nodeRepo, offset: 0, count: 1);
    return result.totalItems;
  }

  @override
  Future<List<MediaNode>> fetch(
    ScenarioSource source,
    MediaNodeRepository nodeRepo, {
    required int offset,
    required int count,
    required ScenarioSortField sortField,
    required SortDirection sortDirection,
    required bool sourceInternalFirst,
  }) async {
    final result = await _query(
      source,
      nodeRepo,
      offset: offset,
      count: count,
      sortField: sortField,
      sortDirection: sortDirection,
      sourceInternalFirst: sourceInternalFirst,
      countTotal: false,
    );
    return result.items;
  }

  Future<MediaNodePageResult> _query(
    ScenarioSource source,
    MediaNodeRepository nodeRepo, {
    required int offset,
    required int count,
    ScenarioSortField sortField = ScenarioSortField.name,
    SortDirection sortDirection = SortDirection.asc,
    bool sourceInternalFirst = false,
    // Window fetches already know the total (count() ran once); skipping the
    // per-window COUNT avoids a full filtered count for every page.
    bool countTotal = true,
  }) {
    final page = (offset ~/ count) + 1;
    // A source whose path resolves to the storage ROOT must use the root query
    // form (parentPath null): its raw absolute path would relativize to an
    // empty string and the recursive-prefix branch would then match nothing,
    // so whole-storage playback resolved to just a placeholder. Recursive at
    // the root means "every file under the storage".
    final atRoot = StoragePathCodec.relativize(
            source.storageId, canonicalDbPath(source.path))
        .isEmpty;
    return nodeRepo.getPagedNodes(
      MediaNodePageQuery(
        page: page,
        pageSize: count,
        storageId: source.storageId,
        parentPath: atRoot ? null : source.path,
        matchAllInStorage: atRoot && source.recursive,
        nodeKind: MediaNodeKind.file,
        // Only playable media enter the queue — excludes MediaType.unknown rows
        // (JSON, images, and any legacy mis-scanned folder rows that were
        // recorded as file nodes) — further narrowed by the browse scope.
        mediaTypes: scopedMediaTypes() ?? const [MediaType.video, MediaType.audio],
        recursive: source.recursive,
        sortField: sortField.toMediaSortField(),
        sortDirection: sortDirection,
        pathGroupFirst: sourceInternalFirst,
        countTotal: countTotal,
      ),
    );
  }
}

/// Resolves a single-path [ScenarioSource] (sourceKind = file) into exactly one
/// playable media — the tapped file itself (A8: mediaId preferred, path fallback).
class FileSourceProvider implements ScenarioSourceProvider {
  const FileSourceProvider();

  @override
  ScenarioSourceKind get kind => ScenarioSourceKind.file;

  @override
  Future<int> count(ScenarioSource source, MediaNodeRepository nodeRepo) async {
    final node = await nodeRepo.getNodeByPath(
      storageId: source.storageId,
      path: _segments(source.path),
    );
    return (node != null && node.isFile) ? 1 : 0;
  }

  @override
  Future<List<MediaNode>> fetch(
    ScenarioSource source,
    MediaNodeRepository nodeRepo, {
    required int offset,
    required int count,
    required ScenarioSortField sortField,
    required SortDirection sortDirection,
    required bool sourceInternalFirst,
  }) async {
    if (offset > 0 || count <= 0) return const [];
    final node = await nodeRepo.getNodeByPath(
      storageId: source.storageId,
      path: _segments(source.path),
    );
    if (node == null || !node.isFile) return const [];
    return [node];
  }

  static List<String> _segments(String path) {
    if (path.isEmpty) return const [];
    return path.split('/').where((e) => e.isNotEmpty).toList();
  }
}
