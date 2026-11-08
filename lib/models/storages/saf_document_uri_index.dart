/// In-memory index of SAF directory document URIs, keyed by storage path.
///
/// WHY: resolving a `content://` subdirectory used to re-walk every segment,
/// and each step is a FULL child query of the parent
/// (`SafUtil().child` → `DocumentsContract` `resolver.query`) that then matches
/// the name linearly. Scanning directory at depth `d` therefore cost `d` extra
/// whole-directory queries on top of its own listing — on a 10k-directory SAF
/// tree that is the difference between seconds and minutes.
///
/// The listing that discovers those directories ALREADY returns each child's
/// document URI, so the descent is pure waste: remember it here and resolve in
/// O(1).
///
/// Bounded and self-healing: paths change on rename/move, and a stale entry
/// would list the wrong directory. The scan clears the index when it starts; on
/// overflow the whole index is dropped (a miss only costs one query).
class SafDocumentUriIndex {
  SafDocumentUriIndex({this.maxEntries = 20000});

  /// Upper bound on remembered directories. 20k directories is roughly 4 MB of
  /// path strings — above that the savings no longer justify the memory on a
  /// phone.
  final int maxEntries;

  final Map<String, String> _byPath = <String, String>{};

  static final SafDocumentUriIndex instance = SafDocumentUriIndex();

  int get length => _byPath.length;

  /// [path] is the full storage-relative list: `[treeUri, rel1, rel2, …]`.
  static String keyOf(List<String> path) => path.join('/');

  String? lookup(List<String> path) => _byPath[keyOf(path)];

  void remember(List<String> path, String documentUri) {
    if (documentUri.isEmpty) return;
    final key = keyOf(path);
    if (_byPath.length >= maxEntries && !_byPath.containsKey(key)) {
      _byPath.clear();
    }
    _byPath[key] = documentUri;
  }

  void clear() => _byPath.clear();

  /// Test seam: forget one entry (a rename/move invalidates only that subtree,
  /// and a miss is harmless).
  void forget(List<String> path) => _byPath.remove(keyOf(path));
}

/// Resolves the document URI of an SAF directory, reusing [index] when possible.
///
/// [child] is `SafUtil().child` in production and a counter in tests.
///
/// Fast path: one `child` call for the WHOLE remaining segment list (the plugin
/// walks the names natively in a single round trip). Slow path (a segment was
/// renamed/removed between the listing and the descent): the historical
/// per-segment walk, returning the nearest existing ancestor so the caller's
/// listing still reflects what is reachable.
Future<String> resolveSafContainerUri({
  required String treeUri,
  required List<String> relativeSegments,
  required Future<String?> Function(String uri, List<String> names) child,
  SafDocumentUriIndex? index,
}) async {
  if (relativeSegments.isEmpty) return treeUri;
  final full = <String>[treeUri, ...relativeSegments];

  final cached = index?.lookup(full);
  if (cached != null) return cached;

  try {
    final documentUri = await child(treeUri, relativeSegments);
    if (documentUri != null) {
      index?.remember(full, documentUri);
      return documentUri;
    }
  } catch (_) {
    // Fall through to the per-segment walk: the one-shot call fails as a whole
    // when any single name is missing.
  }

  var current = treeUri;
  final found = <String>[];
  for (final segment in relativeSegments) {
    try {
      final next = await child(current, <String>[segment]);
      if (next == null) break;
      current = next;
      found.add(segment);
    } catch (_) {
      break;
    }
  }
  if (found.isNotEmpty) {
    index?.remember(<String>[treeUri, ...found], current);
  }
  return current;
}
