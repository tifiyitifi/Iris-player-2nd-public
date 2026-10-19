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
