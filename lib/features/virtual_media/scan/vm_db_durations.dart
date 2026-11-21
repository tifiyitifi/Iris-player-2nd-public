import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/utils/path_conv.dart';

// DB read seam for virtual-media durations. Scans only persist via
// updateFileMediaInfo; every consumer re-reads here (single source of truth).
typedef VmDbDurationReader = Future<Map<String, int?>> Function(
  List<VirtualSegment> segments,
);

/// Default reader: one batched canonical lookup for all segments (null when
/// the row is missing or has no duration).
Future<Map<String, int?>> defaultVmDbDurationReader(
  List<VirtualSegment> segments,
) async {
  final out = <String, int?>{for (final s in segments) s.mediaKey: null};
  if (segments.isEmpty) return out;
  try {
    final keys = {for (final s in segments) s.mediaKey};
    // SAF single-picked rows store an EMPTY path and carry their identity in
    // `uri`; a path-keyed lookup can never see them. Resolve both forms and
    // rebuild keys through the one canonical helper (same as every producer).
    final uris = <String>{
      for (final s in segments)
        if ((s.uri ?? '').isNotEmpty) s.uri!,
    };
    final nodes = await DbModule.mediaNodeRepo
        .nodesByMediaKeysOrUris(keys, alsoByUris: uris);
    final byKey = <String, MediaNode>{};
    for (final n in nodes) {
      final key = n.maybeMap(
        file: (f) => canonicalMediaKey(f.storageId, f.path, uri: f.uri),
        orElse: () => '',
      );
      if (key.isNotEmpty) byKey[key] = n;
    }
    for (final s in segments) {
      final node = byKey[s.mediaKey];
      if (node == null) {
        out[s.mediaKey] = null;
        continue;
      }
      out[s.mediaKey] = node.maybeMap(
        file: (f) => f.durationMs,
        orElse: () => null,
      );
    }
  } catch (_) {
    // Batch failed: keep nulls (callers degrade per-segment, never throw).
  }
  return out;
}
