import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';

/// The scenario queue's ONE global order.
///
/// Every storage's SHARED order is built by `MediaNodesDao`'s ORDER BY, and the
/// queue's base order is a merge of those shared orders. That merge is only
/// representable (non-decreasing ranks per storage) while this comparator agrees
/// with the DAO **column for column** — including the unknown bucket, which is
/// where the old queue visibly broke:
///
///  - `size_in_bytes` / `duration_ms` treat `0` as unknown (the SAF / WebDAV /
///    FTP lanes cannot stat a file, so they report 0). Unknown (`NULL` or `0`)
///    always sorts AFTER every known value, in BOTH directions.
///  - Inside the unknown bucket the raw column still orders rows (SQLite puts
///    `NULL` first on ASC) and the direction still applies, followed by the
///    ascending `natural_name → path` tail. This is exactly what
///    `test/media_dao_zero_is_unknown_test.dart` pins.
///  - Name order is the NATURAL order: `natural_name` stores a key whose byte
///    order is `1 < 2 < 10` (see `lib/utils/natural_sort_key.dart`), so this
///    comparator compares those keys verbatim instead of lower-casing names.
///  - `grouped` (同目录连续) prepends `parent_path` with the same direction.
///  - The tail is ascending in both directions and ends with `storageId` →
///    `occurrencePath`, because `path` is only unique within one storage.
class ScenarioOrderComparator {
  const ScenarioOrderComparator({
    required this.field,
    required this.direction,
    required this.grouped,
  });

  final ScenarioSortField field;
  final SortDirection direction;

  /// 同目录连续: same-parent files form contiguous blocks.
  final bool grouped;

  bool get ascending => direction == SortDirection.asc;

  /// `size`/`duration` 0 is "the lane could not stat it", not "empty".
  bool get _zeroIsUnknown =>
      field == ScenarioSortField.sizeInBytes ||
      field == ScenarioSortField.durationMs;

  int compare(MediaNode a, MediaNode b) {
    if (grouped) {
      final byParent = _compareParent(a, b);
      if (byParent != 0) return _apply(byParent);
    }
    final primary = field == ScenarioSortField.name
        ? _compareName(a, b)
        : _compareNumeric(a, b);
    if (primary != 0) return primary;
    return _tail(a, b);
  }

  int _apply(int result) => ascending ? result : -result;

  int _compareName(MediaNode a, MediaNode b) =>
      _apply(_compareString(_name(a), _name(b)));
  int _compareNumeric(MediaNode a, MediaNode b) {
    final va = _numeric(a);
    final vb = _numeric(b);
    final ua = _isUnknown(va);
    final ub = _isUnknown(vb);
    // Unknown is ALWAYS last — flipping it with the direction is the bug.
    if (ua != ub) return ua ? 1 : -1;
    if (ua) {
      // Both unknown: the DAO still orders by the raw column, NULL first on ASC.
      final raw = va == null
          ? (vb == null ? 0 : -1)
          : (vb == null ? 1 : va.compareTo(vb));
      return _apply(raw);
    }
    return _apply(va!.compareTo(vb!));
  }

  bool _isUnknown(int? value) =>
      value == null || (_zeroIsUnknown && value == 0);

  int _tail(MediaNode a, MediaNode b) {
    // The DAO's tail: natural-name key, then path. Kept ascending in both
    // directions so ties are stable and windowed paging cannot shuffle them.
    if (field != ScenarioSortField.name) {
      final byName = _compareString(_name(a), _name(b));
      if (byName != 0) return byName;
    }
    final byPath = _compareString(_path(a), _path(b));
    if (byPath != 0) return byPath;
    // Cross-storage tie-break: `path` is unique only inside one storage.
    final byStorage = _compareString(a.storageId, b.storageId);
    if (byStorage != 0) return byStorage;
    // A SAF single-picked file has an empty path; its document uri is the only
    // identity, and it is what the occurrence id uses.
    return _compareString(a.occurrencePath, b.occurrencePath);
  }

  int? _numeric(MediaNode node) {
    switch (field) {
      case ScenarioSortField.name:
        return null;
      case ScenarioSortField.modifiedAt:
        return node.modifiedAt?.millisecondsSinceEpoch;
      case ScenarioSortField.durationMs:
        return node.maybeMap(file: (f) => f.durationMs, orElse: () => null);
      case ScenarioSortField.sizeInBytes:
        return node.maybeMap(file: (f) => f.sizeInBytes, orElse: () => null);
    }
  }

  static String _name(MediaNode node) => node.naturalNameValue;

  /// SQLite `ORDER BY parent_path` semantics, which the paged DAO uses verbatim:
  /// NULL sorts before EVERY value in ascending order, and a stored `''` is a
  /// distinct value (pre-fix scans wrote it for root children). Mapping both to
  /// `''` merged two groups the DB keeps apart, so a legacy root row could sit
  /// in the wrong group relative to the paged order.
  static int _compareParent(MediaNode a, MediaNode b) {
    final pa = a.parentPath;
    final pb = b.parentPath;
    if (pa == pb) return 0;
    if (pa == null) return -1;
    if (pb == null) return 1;
    return pa.compareTo(pb);
  }

  static String _path(MediaNode node) => node.path.join('/');

  static int _compareString(String a, String b) => a.compareTo(b);
}
