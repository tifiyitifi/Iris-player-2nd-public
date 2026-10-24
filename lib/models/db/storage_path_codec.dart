import 'package:iris/utils/path_conv.dart';

/// Converts between the DOMAIN path form and the DB-stored path form for
/// `media_nodes`.
///
/// - DOMAIN: absolute, storage-base-inclusive, canonical (`D:/Movies/a.mp4`,
///   `storage/emulated/0/Movies/a.mp4`, `<treeUri>/Movies/a.mp4`).
/// - DB: relative to the storage's base path (`Movies/a.mp4`, `''` = root).
///
/// The DB form is the stable identity: a drive-letter reassignment changes only
/// the storage's `base_path`, never the stored rows, so a re-mounted disk needs
/// ZERO media-node writes. The base is resolved from the owning entry's id via
/// [baseResolver] (wired at startup from the storage store).
///
/// Both directions are IDEMPOTENT: a path already in the target form passes
/// through unchanged. That makes it safe to call on either form at every
/// boundary, so a missed conversion can never corrupt a path by stripping or
/// prepending twice.
abstract final class StoragePathCodec {
  /// Resolves a storage id to its absolute base segments (e.g. `['D:']`), or
  /// null when the storage is unknown / has no meaningful base (remote root
  /// `/`, empty) — in which case no conversion happens.
  static List<String>? Function(String storageId) baseResolver = (_) => null;

  static List<String>? _baseSegments(String storageId) {
    final base = baseResolver(storageId);
    if (base == null || base.isEmpty) return null;
    final canonical = canonicalDbPath(base.join('/'));
    if (canonical.isEmpty) return null;
    // Android SAF tree URIs are stable and path-embedded on purpose; leaving
    // them absolute keeps the SAF resolution/backfill logic unchanged.
    if (isSafPath(canonical)) return null;
    final segments = pathConv(canonical);
    return segments.isEmpty ? null : segments;
  }

  /// DOMAIN (absolute) → DB (relative) canonical string.
  static String relativize(String storageId, String domainCanonical) {
    final base = _baseSegments(storageId);
    if (base == null) return domainCanonical;
    return relativizeForBase(base, domainCanonical);
  }

  /// [relativize] over a RAW caller path. Repairs the historical shapes first
  /// (`E:\a`, the legacy `/E:/a`, duplicated slashes) so identity comparisons
  /// never depend on how the caller spelled the path.
  ///
  /// This is the ONLY entry point path-keyed operations (delete / merge /
  /// occurrence keys) should use: hand-built joins are what produced the
  /// "row never deleted" and "same file under two keys" classes of bug.
  static String relativizeRaw(String storageId, String raw) {
    final base = _baseSegments(storageId);
    if (base == null) return canonicalDbPath(normalizePathText(raw));
    return relativizeForBase(base, raw);
  }

  /// [relativize] against an EXPLICIT base. Used where the storage store is not
  /// the authority (the duplicate-entry merge, pure tests).
  static String relativizeForBase(List<String>? base, String raw) {
    final canonical = canonicalDbPath(normalizePathText(raw));
    if (base == null || base.isEmpty) return canonical;
    // SAF identity is path-embedded and never re-rooted.
    if (isSafPath(canonical)) return canonical;
    final baseSegments = pathConv(canonicalDbPath(base.join('/')));
    if (baseSegments.isEmpty) return canonical;
    final segments = pathConv(canonical);
    if (segments.length < baseSegments.length) return canonical;
    // Compare the base the way the filesystem does: NTFS/UNC fold case, POSIX
    // and SAF stay exact. The stored relative path keeps the caller's case.
    final fold = baseRidesCaseInsensitiveFs(base);
    for (var i = 0; i < baseSegments.length; i++) {
      final a = fold ? segments[i].toLowerCase() : segments[i];
      final b = fold ? baseSegments[i].toLowerCase() : baseSegments[i];
      if (a != b) return canonical;
    }
    return segments.sublist(baseSegments.length).join('/');
  }

  /// Whether a base rides a case-insensitive filesystem (NTFS drive or UNC
  /// share). POSIX / SAF bases stay case-sensitive.
  static bool baseRidesCaseInsensitiveFs(List<String>? base) =>
      base != null && base.isNotEmpty && pathRidesCaseInsensitiveFs(base.join('/'));

  /// Case-folded comparison key for [raw] under [storageId].
  ///
  /// Two spellings of the same NTFS file (`E:/YB/a.mp4`, `E:\yb\a.mp4`,
  /// `yb/a.mp4`) collapse to one key; POSIX and SAF stay case-sensitive.
  static String relativeKey(String storageId, String raw) =>
      relativeKeyForBase(_baseSegments(storageId), raw);

  /// [relativeKey] against an EXPLICIT base (merge service / tests).
  static String relativeKeyForBase(List<String>? base, String raw) {
    final relative = relativizeForBase(base, raw);
    return baseRidesCaseInsensitiveFs(base)
        ? relative.toLowerCase()
        : relative;
  }


  /// DB (relative) → DOMAIN (absolute) canonical string.
  static String absolutize(String storageId, String storedCanonical) {
    final base = _baseSegments(storageId);
    if (base == null) return storedCanonical;
    final segments = pathConv(storedCanonical);
    if (segments.length >= base.length) {
      var alreadyAbsolute = true;
      for (var i = 0; i < base.length; i++) {
        if (segments[i] != base[i]) {
          alreadyAbsolute = false;
          break;
        }
      }
      if (alreadyAbsolute) return storedCanonical;
    }
    return [...base, ...segments].join('/');
  }

  /// Whether two storage base paths name the SAME path ROOT.
  ///
  /// The duplicate-entry repair, its merge guard and the path-keyed scope family
  /// must all answer this ONE question the same way: an NTFS drive or UNC share
  /// folds case (`E:/Movies` and `e:/movies` are one root, however the entry was
  /// spelled), while POSIX and SAF bases stay exact. A genuinely different base
  /// is a different root — folding those would re-interpret every stored
  /// relative path.
  ///
  /// Compares the base ONLY; callers that also need the same volume (the
  /// duplicate planner, the scope family) check that separately.
  static bool sameBasePath(List<String>? a, List<String>? b) {
    if (a == null || b == null) return false;
    final ca = canonicalDbPath(normalizePathText(a.join('/')));
    final cb = canonicalDbPath(normalizePathText(b.join('/')));
    if (ca == cb) return true;
    final fold = baseRidesCaseInsensitiveFs(a) || baseRidesCaseInsensitiveFs(b);
    return fold && ca.toLowerCase() == cb.toLowerCase();
  }

  /// True when [storedCanonical] names a directory ABOVE the storage base
  /// (a strict ancestor prefix of it), e.g. stored `F:/dl` with base
  /// `F:/dl/ar`.
  ///
  /// Such rows are phantoms: pre-fix scans built directory nodes from
  /// absolute segments, so the base itself and everything above it leaked
  /// into the DB. The topmost phantom carries a NULL parent, which every
  /// root-level read mistakes for a real root child.
  static bool isAboveBase(String storageId, String storedCanonical) {
    final base = _baseSegments(storageId);
    if (base == null || storedCanonical.isEmpty) return false;
    final b = base.join('/');
    return b != storedCanonical && b.startsWith('$storedCanonical/');
  }

  /// True when [storedCanonical] is the storage base itself in ABSOLUTE form
  /// (e.g. stored `F:` with base `F:`, or stored `F:/dl/ar` with base
  /// `F:/dl/ar`).
  ///
  /// Pre-fix scans built the storage-root self node from absolute segments,
  /// so old databases may carry the root twice: this absolute row plus (after
  /// a fixed scan) the relative `''` row. The absolute row is a phantom: it
  /// can never be addressed through [relativize] (which maps it to `''`), and
  /// with a NULL parent on a drive-root base it counts as an unscanned root
  /// child forever, permanently blocking the root `scanDone` stamp.
  /// [isAboveBase] does NOT match it (it is the base itself, not strictly
  /// above it), hence the separate predicate. Remove it by EXACT stored-path
  /// match only — never by prefix: its relativized form is `''`, and a prefix
  /// delete on `''` would wipe the real root container instead.
  static bool isStaleAbsoluteBase(String storageId, String storedCanonical) {
    if (storedCanonical.isEmpty) return false;
    final base = _baseSegments(storageId);
    if (base == null) return false;
    if (storedCanonical != base.join('/')) return false;
    return relativize(storageId, storedCanonical).isEmpty;
  }
}
