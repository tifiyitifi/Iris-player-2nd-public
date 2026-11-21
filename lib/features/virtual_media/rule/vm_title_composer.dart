import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';

/// Fixed marker prepended to a virtual merged item's DISPLAY name in the
/// scenario play queue and search results. Language-neutral (identical in
/// every locale) so it doubles as a searchable token: typing `vm` surfaces
/// every merged virtual item. Never part of the persisted media name.
const String kVmDisplayPrefix = '[vm] ';

/// Composes a virtual item's display title from lit [VmTitleTag]s.
///
/// The tag list order IS the concatenation order (点亮顺序即标题顺序) —
/// there is no reorder control. Pieces that carry no information (e.g.
/// resolution when unprobed) are omitted entirely. The result never
/// contains user-authored templates, so no escaping surface exists; the
/// special-char concerns live in the internal keys (scopeKey/anchor), which
/// are built from canonical library paths only.
///
/// [seq] is the item's CHUNK number within its rule — "this is the Nth merged
/// block", which is information the list's own leading position column does NOT
/// carry (that column counts every row, merged or not). Keep the two distinct:
/// a title whose number equals the row's position is pure duplication, and the
/// `seq` tag would then have no reason to be a toggle at all.
String composeVmTitle({
  required List<VmTitleTag> tags,
  required String ruleName,
  required String dirName,
  required String firstFile,
  required String lastFile,
  required int seq,
  required int totalDurationMs,
  required int? width,
  required int? height,
}) {
  String stripExt(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  final pieces = <String>[];
  for (final tag in tags) {
    switch (tag) {
      case VmTitleTag.ruleName:
        if (ruleName.isNotEmpty) pieces.add(ruleName);
      case VmTitleTag.dirName:
        if (dirName.isNotEmpty) pieces.add(dirName);
      case VmTitleTag.firstFile:
        final v = stripExt(firstFile);
        if (v.isNotEmpty) pieces.add(v);
      case VmTitleTag.lastFile:
        final v = stripExt(lastFile);
        if (v.isNotEmpty) pieces.add(v);
      case VmTitleTag.seq:
        pieces.add('$seq');
      case VmTitleTag.duration:
        final v = _fmtDuration(totalDurationMs);
        if (v.isNotEmpty) pieces.add(v);
      case VmTitleTag.resolution:
        if (width != null && height != null) pieces.add('$width×$height');
    }
  }
  if (pieces.isEmpty) return dirName;
  return pieces.join(' · ');
}

/// Player title replacement for a virtual item (spec §9.2): replaces the
/// single-file name part with `dirName + sep + index/total + sep + origName`.
String vmPlayerTitle({
  required String dirName,
  required int innerIndex,
  required int innerTotal,
  required String origName,
  String separator = ':',
}) {
  // Honour the configured separator verbatim; truncating to its first code
  // unit silently changed a multi-character choice.
  final sep = separator.isEmpty ? ':' : separator;
  return '$dirName$sep$innerIndex/$innerTotal$sep$origName';
}

/// Compact duration: `1h30m`, `45m`, `30s`; zero/unknown → ''.
String _fmtDuration(int ms) {
  if (ms <= 0) return '';
  final d = Duration(milliseconds: ms);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '${h}h${m.toString().padLeft(2, '0')}m';
  if (m > 0) {
    return s > 0 ? '${m}m${s.toString().padLeft(2, '0')}s' : '${m}m';
  }
  return '${s}s';
}
