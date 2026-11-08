import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/utils/natural_sort_key.dart';

/// Builds a single-level comparator for a rule's [VmSortField].
///
/// Guarantees:
/// - Nullable probe fields (duration/dimensions) sort LAST no matter the
///   direction — unprobed files never jump above probed ones.
/// - A stable MediaKey ascending tie-breaker is always appended so resolver
///   output is deterministic across re-resolves.
int compareSegments(
    VirtualSegment a, VirtualSegment b, VmSortField field, SortDirection dir) {
  final cmp = _compareField(a, b, field, dir);
  if (cmp != 0) return cmp;
  return a.mediaKey.compareTo(b.mediaKey);
}

List<VirtualSegment> sortSegments(
    List<VirtualSegment> segments, VmSortField field, SortDirection dir) {
  final out = [...segments];
  out.sort((a, b) => compareSegments(a, b, field, dir));
  return out;
}

int _compareField(VirtualSegment a, VirtualSegment b, VmSortField field,
    SortDirection dir) {
  final sign = dir == SortDirection.asc ? 1 : -1;

  switch (field) {
    case VmSortField.fileName:
      return sign * naturalCompare(a.name, b.name);
    default:
      break;
  }

  final va = _numericValue(a, field);
  final vb = _numericValue(b, field);

  // Nulls last REGARDLESS of direction.
  if (va == null && vb == null) return 0;
  if (va == null) return 1;
  if (vb == null) return -1;

  return sign * va.compareTo(vb);
}

num? _numericValue(VirtualSegment s, VmSortField field) => switch (field) {
      VmSortField.duration => s.durationMs,
      VmSortField.resolution =>
        (s.width == null || s.height == null)
            ? null
            : s.width! * s.height!,
      VmSortField.aspectRatio => _aspectRatio(s),
      VmSortField.width => s.width,
      VmSortField.height => s.height,
      VmSortField.fileName => null,
    };

double? _aspectRatio(VirtualSegment s) {
  final w = s.width;
  final h = s.height;
  if (w == null || h == null || h == 0) return null;
  return w / h;
}
