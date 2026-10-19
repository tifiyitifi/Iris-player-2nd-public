import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/file.dart' show Subtitle;

/// Where a search result came from — drives the tile subtitle badge in the
/// scenario context (F-008 / D4).
enum SearchResultOrigin {
  /// Returned by the DB range query over the current search sources.
  dbSource,

  /// Synthesized from a scenario explicit item (not in DB, or outside the
  /// current search source scope).
  explicitItem,

  /// A Virtual Media merged group derived from the scenario's effective
  /// stream (never in the DB). [vmScopeKey] identifies it; [storageId]/[path]
  /// point at the group's FIRST segment so playback/open-folder reuse the
  /// ordinary paths.
  virtualGroup,
}

/// A search page result: either a DB `MediaFile` row (origin = dbSource) or a
/// synthesized explicit-item entry (origin = explicitItem, possibly not in DB).
///
/// Flat value type so it can be used directly as the tile generic `T`
/// (`UnifiedItemTile<SearchResultItem>`); the tile's title/subtitle/leading are
/// delegated by the data source.
class SearchResultItem {
  final String storageId;
  final String path;
  final String name;
  final MediaType mediaType;
  final int? sizeInBytes;
  final int? durationMs;

  /// Real SAF `content://` document URI for dbSource rows (null otherwise) so
  /// DB-resolved SAF search results stay playable/probeable.
  final String? uri;

  /// External subtitle associations persisted on the DB row (schema v50).
  /// Null for synthetic rows (explicit items / VM groups), which have none.
  final List<Subtitle>? subtitles;

  final SearchResultOrigin origin;

  /// False for synthetic explicit items whose file is not in the media DB —
  /// such entries cannot really be played (Q8 / v5-D5).
  final bool available;

  /// Virtual Media group identity (`ruleId|dir|#seq`) when
  /// [origin] == [SearchResultOrigin.virtualGroup]; null otherwise.
  final String? vmScopeKey;

  /// Segment count of a virtual group (subtitle annotation).
  final int? segmentCount;

  /// Occurrence index of the group's representative file — required to start
  /// the merged session through `resolveItemByOccurrenceFor`.
  final int? occurrenceIndex;

  const SearchResultItem({
    required this.storageId,
    required this.path,
    required this.name,
    this.mediaType = MediaType.unknown,
    this.sizeInBytes,
    this.durationMs,
    this.uri,
    this.subtitles,
    required this.origin,
    this.available = true,
    this.vmScopeKey,
    this.segmentCount,
    this.occurrenceIndex,
  });

  /// True for a Virtual Media merged group.
  bool get isVirtualGroup => origin == SearchResultOrigin.virtualGroup;

  /// Canonical stable identity across the DB and explicit segments. Virtual
  /// groups use their scope key — the representative file also exists as a DB
  /// row, so `storageId:path` would collide.
  String get id =>
      isVirtualGroup ? 'vm:$vmScopeKey' : '$storageId:$path';
}
