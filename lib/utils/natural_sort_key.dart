/// Natural ("digit aware") ordering: `2` sorts before `10`, `ep2` before
/// `ep10`, and leading zeros keep a deterministic order (`7` before `007`).
///
/// ## Why a materialized KEY and not a comparator
///
/// The database can only order by a plain BINARY column. A Dart comparator that
/// implements the numeric rules by hand would have to agree with SQLite column
/// for column, forever — exactly the class of drift that
/// `ScenarioOrderComparator` already warns about. Instead the ordering is
/// defined ONCE, as a string whose byte order IS the natural order:
///
///     naturalCompare(a, b) == naturalSortKey(a).compareTo(naturalSortKey(b))
///
/// `media_nodes.natural_name` stores that key, `ORDER BY natural_name` follows,
/// and the in-memory sorts compare the same key. Parity is by construction.
///
/// ## Encoding
///
/// The name is lower-cased, then split into maximal digit / non-digit runs:
///
/// - digit run → `0x01` + 3-digit digit-count + the digits (leading zeros
///   stripped) + 2-digit leading-zero count
/// - text run  → `0x02` + the lower-cased text
///
/// Markers keep the runs self-delimiting; `0x01 < 0x02` puts digits before
/// letters (the file-manager convention). Comparing the stripped digit COUNT
/// first is what makes arbitrary-length numbers correct — a fixed-width
/// zero-padded value would silently misrank a 13-digit run.
///
/// Divergence from VLC (`vlc_filenamecmp`): VLC falls back to `strcoll` when two
/// numbers are numerically equal, so it orders `007` BEFORE `7`. This key ranks
/// the shorter leading-zero run first (`7` before `007`) because that is what
/// IRIS's existing `vmNaturalCompare` does. Both are deterministic; IRIS keeps
/// its own behaviour so the VM list does not reshuffle.
///
/// Case-only differences produce the SAME key on purpose: the caller's tail
/// (`path`, or a media key) breaks the tie deterministically, and the tail is
/// case-sensitive, so `A.mkv` still precedes `a.mkv`.
const int _digitMarker = 0x01;
const int _textMarker = 0x02;

/// The sort key of [name]. Byte order == natural order (see file header).
String naturalSortKey(String name) {
  if (name.isEmpty) return '';
  final lower = name.toLowerCase();
  final out = StringBuffer();
  var i = 0;
  while (i < lower.length) {
    if (_isDigit(lower.codeUnitAt(i))) {
      var end = i;
      while (end < lower.length && _isDigit(lower.codeUnitAt(end))) {
        end++;
      }
      var stripped = i;
      while (stripped < end && lower.codeUnitAt(stripped) == _zero) {
        stripped++;
      }
      final digits = lower.substring(stripped, end);
      out.writeCharCode(_digitMarker);
      out.write(digits.length.toString().padLeft(3, '0'));
      out.write(digits);
      out.write((stripped - i).toString().padLeft(2, '0'));
      i = end;
    } else {
      var end = i;
      while (end < lower.length && !_isDigit(lower.codeUnitAt(end))) {
        end++;
      }
      var text = lower.substring(i, end);
      // The markers must stay unambiguous: a name containing them is illegal on
      // every supported filesystem, but a WebDAV/SMB share can still report one.
      if (text.contains('\u0001') || text.contains('\u0002')) {
        text = text.replaceAll('\u0001', '').replaceAll('\u0002', '');
      }
      out.writeCharCode(_textMarker);
      out.write(text);
      i = end;
    }
  }
  return out.toString();
}

/// Natural comparison of two display names.
///
/// Prefer pre-computing [naturalSortKey] once per item when sorting a large
/// list (measurably cheaper than re-encoding on every comparison).
int naturalCompare(String a, String b) =>
    naturalSortKey(a).compareTo(naturalSortKey(b));

/// In-place stable sort by the natural order of [keyOf].
///
/// Encodes each item's key ONCE (decorate-sort) instead of re-encoding on every
/// comparison: on a 500k stream that is ~2.8 s versus ~12.6 s for a comparator
/// that computes keys inline, and it keeps ties in their original order.
void sortByNaturalKey<T>(
  List<T> items,
  String Function(T item) keyOf, {
  bool descending = false,
}) {
  if (items.length < 2) return;
  final decorated = <(String, int)>[
    for (var i = 0; i < items.length; i++) (naturalSortKey(keyOf(items[i])), i),
  ];
  decorated.sort((a, b) {
    final byKey = descending ? b.$1.compareTo(a.$1) : a.$1.compareTo(b.$1);
    // Original position breaks key ties, so the sort is stable.
    return byKey != 0 ? byKey : a.$2.compareTo(b.$2);
  });
  final ordered = <T>[for (final (_, index) in decorated) items[index]];
  items
    ..clear()
    ..addAll(ordered);
}

const int _zero = 0x30;

bool _isDigit(int code) => code >= 0x30 && code <= 0x39;
