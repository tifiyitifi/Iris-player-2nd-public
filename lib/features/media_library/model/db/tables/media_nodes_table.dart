import 'package:drift/drift.dart';
import 'package:iris/features/media_library/model/db/adapters/epoch_millis_converter.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart' show MediaType;

/// SQLite INTEGER = signed 64-bit.
///
/// Max:
/// 9,223,372,036,854,775,807 bytes
///
/// ≈ 8 EiB
/// ≈ 9.22 EB
/// ≈ 9.2 million terabytes (TB).
/// More than sufficient for any realistic media library.
class MediaNodesTable extends Table {
  @override
  String get tableName => 'media_nodes';

  IntColumn get id => integer().autoIncrement()();

  TextColumn get storageId => text()();

  /// Canonical data scope (v31). Equals [storageId] for an independent entry;
  /// two entries linked as "same account + same/contained tree" share one
  /// scope, so their scanned nodes live in a single row set.
  ///
  /// Nullable so pre-v31 rebuild migrations (v4/v9/v15/…) can copy rows without
  /// knowing the column; v31 back-fills every row with `storage_id` and all
  /// writers set it explicitly. Uniqueness is enforced on
  /// `(data_scope_id, path)` — see [customConstraints] — which holds once the
  /// back-fill has run.
  TextColumn get dataScopeId => text().nullable()();

  TextColumn get path => text()();

  TextColumn get parentPath => text().nullable()();

  /// Depth in directory tree:
  /// 0 = root storage
  /// 1 = Movies
  /// 2 = Movies/Action
  IntColumn get pathDepth => integer().withDefault(const Constant(0))();

  TextColumn get name => text()();
  // normalizedName = name.toLowerCase();
  /// lowercase cache for search/sort
  TextColumn get normalizedName => text().nullable()();
  // dir or file
  TextColumn get nodeKind => textEnum<MediaNodeKind>()();
  // video or audio,
  TextColumn get mediaType => textEnum<MediaType>().nullable()();
  //
  // file
// File properties
  IntColumn get sizeInBytes => integer().nullable()();
  IntColumn get durationMs => integer().nullable()();

  // ── Deep-probe media info (optional scan probe / lazy playback backfill) ──
  /// Video frame width in pixels. NULL = not probed yet.
  ///
  /// Rescan-preserving: omitted from upsert companions so a plain rescan
  /// never wipes probed values (same rule as the playback_* columns).
  IntColumn get width => integer().nullable()();

  /// Video frame height in pixels. NULL = not probed yet.
  IntColumn get height => integer().nullable()();

  /// Cached `width * height` for resolution sorting; NULL when unknown.
  /// Stored at probe time so ORDER BY stays a plain indexed-friendly column.
  IntColumn get pixelCount => integer().nullable()();

  /// Real playable/probe URI for Android SAF rows (`content://` document URI),
  /// captured at browse/scan time from the listing's FileItem.uri. NULL for
  /// ordinary filesystem rows — read side falls back to `playableUri(path)`.
  ///
  /// Rescan-preserving like the probe columns: absent keeps the stored value.
  TextColumn get uri => text().nullable()();

  /// External subtitle associations captured from the listing's FileItem
  /// (`getSubtitleMap`), stored as a JSON array of `{"name","uri"}`.
  ///
  /// NULL means UNKNOWN — the row predates schema v50, or it was written by a
  /// lane that cannot see subtitles (playback backfill, manual node edit). An
  /// empty list is stored as `'[]'` and means "KNOWN to have none". Keeping the
  /// two apart lets the incremental scan enrich a row exactly once instead of
  /// rewriting every file on every scan.
  ///
  /// Rescan-preserving: absent keeps the stored value, so a writer that does not
  /// know the associations never clears them.
  TextColumn get subtitlesJson => text().nullable()();

  //
  // dir
  // Aggregates
  IntColumn get directMediaCount => integer().withDefault(const Constant(0))();
  IntColumn get directDirCount => integer().withDefault(const Constant(0))();
  IntColumn get directItemCount => integer().withDefault(const Constant(0))();

  IntColumn get totalMediaCount => integer().withDefault(const Constant(0))();
  IntColumn get totalDirCount => integer().withDefault(const Constant(0))();
  IntColumn get totalItemCount => integer().withDefault(const Constant(0))();
  IntColumn get totalSizeInBytes => integer().withDefault(const Constant(0))();
  IntColumn get totalDurationMs => integer().withDefault(const Constant(0))();
  //
  /// File/scan modification time, stored as epoch **milliseconds**.
  ///
  /// Sub-second precision matters for ordering: whole seconds made files written
  /// in the same second compare equal. Declared as an int column because the
  /// underlying SQLite column IS an INTEGER — [EpochMillisConverter] supplies
  /// the `DateTime?` type the generated row class and the read/write sites use.
  /// [createdAt] deliberately keeps Drift's default (seconds) mapping — the
  /// scanner never writes it.
  IntColumn get modifiedAt =>
      integer().map(const EpochMillisConverter()).nullable()();

  /// For filesystem content:
  //
  /// createdAt
  ///
  /// is often unavailable or unreliable across Android storage providers.
  DateTimeColumn get createdAt => dateTime().nullable()();

  // important for sync
  BoolColumn get isPresent => boolean().withDefault(const Constant(true))();
  DateTimeColumn get lastSeenAt => dateTime().nullable()();

  /// Whether a recursive scan has completed for this directory.
  BoolColumn get isScanDone => boolean().withDefault(const Constant(false))();

  /// When the last recursive scan completed for this directory.
  DateTimeColumn get lastScanAt => dateTime().nullable()();

  /// Recursive-scan status enum as text:
  /// `notScan` (never scanned) | `scanning` | `scanDone` | `error`.
  ///
  /// `scanDone` is kept in sync with [isScanDone]=true + [lastScanAt] (the
  /// scan-resume path reads the legacy columns). Missing rows and NULL both
  /// mean `notScan`.
  TextColumn get scanState =>
      text().withDefault(const Constant('notScan'))();

  // ── Global per-file playback progress (uniform across all scenarios) ──
  /// Last resume position of the file.
  IntColumn get playbackPositionMs => integer().nullable()();

  /// Finished-watching marker.
  BoolColumn get playbackCompleted => boolean().withDefault(const Constant(false))();

  /// Last playback time.
  DateTimeColumn get lastPlayedAt => dateTime().nullable()();

  /// Play count.
  IntColumn get playCount => integer().withDefault(const Constant(0))();

  /// Remaining times the open-resume path may consult HistoryStore when the
  /// media_nodes row carries no usable position (≤0). NULL/0 = no fallback.
  ///
  /// A real single video whose row was momentarily cleared (or written as 0
  /// by a racing file-switch save) gets a short budget so the history
  /// fallback can restore it across a quick prev/next cycle. A VM sequential
  /// advance pre-writes 0 with budget 0 — an explicit "from the beginning"
  /// that must never be resurrected by a stale history entry.
  IntColumn get historyRestoreBudget => integer().nullable()();

  @override
  List<String> get customConstraints => ['UNIQUE(data_scope_id, path)'];
}
