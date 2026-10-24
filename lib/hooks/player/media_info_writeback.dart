/// Write-once-per-file gate for the foreground players' lazy `media_nodes`
/// backfill.
///
/// Both player hooks write a file's duration/dimensions to `media_nodes` the
/// first time the backend reports them. The mark has to be keyed by the FILE it
/// was written for: a plain "already written once" boolean stayed set for the
/// whole hook lifetime, so every file played after the first was silently
/// skipped and its duration/dimensions never reached the database (the 副音
/// probe and the VM segment-duration guard then had nothing to read).
class MediaInfoWritebackGate {
  String? _durationKey;
  String? _dimsKey;

  /// Whether the values currently reported by the player may be attributed to
  /// the file the hook is bound to.
  ///
  /// The hook's `file` (and so its media key) changes on a track switch BEFORE
  /// the backend resets `duration` / `videoParams`: `open()` is awaited inside
  /// another effect, so the first build of the new file still carries the
  /// PREVIOUS media's values. Writing them keyed by the NEW file poisoned
  /// `media_nodes` — every row ended up with its predecessor's duration and
  /// dimensions (a 44 s clip row showing the 5:47 of the file played before it,
  /// dimensions taken from a different file), and the write-once mark below then
  /// dropped the real values arriving moments later.
  ///
  /// [openedUri] is the hook's `openedMediaUri` — null until THIS file's open
  /// completed and never the uri of a superseded open.
  bool belongsToOpenFile({
    required String? mediaUri,
    required String? openedUri,
  }) =>
      mediaUri != null && openedUri == mediaUri;

  /// Whether the duration of [mediaKey] still has to be written.
  ///
  /// A zero duration is the backend's "not parsed yet" and a null [mediaKey]
  /// (no current file) is nothing to write.
  bool needsDuration(String? mediaKey, int durationMs) =>
      mediaKey != null && durationMs != 0 && _durationKey != mediaKey;

  /// Whether the dimensions of [mediaKey] still have to be written.
  bool needsDims(String? mediaKey, int width, int height) =>
      mediaKey != null && width > 0 && height > 0 && _dimsKey != mediaKey;

  /// Records that [mediaKey]'s duration write was issued.
  void markDurationWritten(String? mediaKey) => _durationKey = mediaKey;

  /// Records that [mediaKey]'s dimensions write was issued.
  void markDimsWritten(String? mediaKey) => _dimsKey = mediaKey;

  /// Releases [mediaKey]'s marks after the write they stood for turned out to be
  /// a NO-OP (no matching `media_nodes` row, or nothing to key a write on) or
  /// threw.
  ///
  /// The mark has to be taken BEFORE the async write so a re-entrant effect run
  /// cannot issue a duplicate write; releasing it on failure is what keeps that
  /// optimistic mark from eating the backfill: the duration/dimensions would
  /// otherwise never reach the database for this file again (the 副音 probe and
  /// the VM duration guard then have nothing to read).
  ///
  /// Only [mediaKey]'s own mark is released: an in-flight write for a file the
  /// player has already left must never clear the CURRENT file's mark.
  void unmark(String? mediaKey) {
    if (_durationKey == mediaKey) _durationKey = null;
    if (_dimsKey == mediaKey) _dimsKey = null;
  }
}

/// Whether a written-back triple CHANGED what the row already stored.
///
/// Such a write is the only case where open lists have to re-resolve: a value
/// that was already correct changes no order and no subtitle, and refreshing
/// for it would cost a queue re-fetch on every single play. A `null` stored
/// duration counts as a change — filling it moves the row out of the
/// NULLS-LAST bucket of every duration sort.
///
/// Dimensions are compared only when BOTH sides are known: the player hooks key
/// their write on the `FileItem`, which carries no resolution, so an unknown
/// stored side must never look like a correction.
bool mediaInfoCorrects({
  required int? storedDurationMs,
  required int durationMs,
  int? storedWidth,
  int? storedHeight,
  int? width,
  int? height,
}) {
  if (storedDurationMs != durationMs) return true;
  if (storedWidth == null ||
      storedHeight == null ||
      width == null ||
      height == null) {
    return false;
  }
  return storedWidth != width || storedHeight != height;
}
