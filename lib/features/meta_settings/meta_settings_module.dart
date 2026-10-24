import 'package:iris/features/meta_settings/bridge/blob_importer.dart';
import 'package:iris/features/meta_settings/bridge/state_bridge.dart';
import 'package:iris/features/meta_settings/contributions/settings_catalog.dart';
import 'package:iris/features/meta_settings/contributions/feature_flags_contribution.dart';
import 'package:iris/features/meta_settings/data/value_codec.dart';
import 'package:iris/features/meta_settings/model/db/dao/settings_dao.dart';
import 'package:iris/features/meta_settings/model/db/repositories/settings_db_repository.dart';
import 'package:iris/models/db/app_database.dart';

/// Composition root of the metadata-settings subsystem.
///
/// Called once from DbModule.init AFTER the database is open and BEFORE any
/// store reads (AppStore.load routes through [repo] when the gate is on).
/// Seeding is idempotent upsert: contribution lists are the authority for
/// defs/flags, the DB mirror simply follows them.
class MetaSettingsModule {
  MetaSettingsModule._();

  // Non-final: tests re-init per test with a fresh in-memory DB; production
  // calls init exactly once from DbModule.
  static SettingsDbRepository repo = _uninitialized();
  static LegacyBlobImporter? _importer;
  static bool _ready = false;

  /// Optional runtime write gate for AUX preference domains.
  ///
  /// Injected by app startup as `() => useAppStore().state.useMetadataSettings`
  /// (this module stays state-model agnostic and must not import the store).
  /// When it returns false, AUX preference writes are dropped so a legacy-mode
  /// run can never clobber data that a later gate-ON re-hydrates. Null (tests
  /// / early boot) means "allow" — provenance of every write stays callers'.
  static bool Function()? writeGate;

  static bool get _writeAllowed => writeGate?.call() ?? true;

  static SettingsDbRepository _uninitialized() =>
      throw StateError('MetaSettingsModule.init() has not run');

  /// True once [init] completed this launch. The AppStore gate path degrades
  /// to the legacy blob when false (e.g. tests that never wire the DB).
  static bool get ready => _ready;

  static Future<void> init(AppDatabase db) async {
    repo = SettingsDbRepository(SettingsDao(db));
    _importer = LegacyBlobImporter(repo);
    await repo.seedDefs(SettingsCatalog.defs);
    await repo.seedFlags(FeatureFlagsContribution.flags);
    _ready = true;
  }

  /// First gate-on boot: seed value rows from the legacy blob (idempotent).
  static Future<bool> importLegacyBlobIfNeeded(
          Map<String, dynamic> legacyJson) =>
      _importer?.importIfNeeded(legacyJson) ?? Future.value(false);

  /// Persists an AUXILIARY-domain row (e.g. `scan.` preferences).
  ///
  /// Unlike [persistState] this upserts ONE key: auxiliary rows must never
  /// touch (let alone replace) the `app.` full-state snapshot. Gate checking
  /// is the caller's concern — this module stays state-model agnostic.
  static Future<void> persistAuxRow(String key, String encoded) async {
    if (!_ready) return;
    if (!_writeAllowed) {
      metaLog.i('persistAuxRow($key): skipped, metadata gate OFF');
      return;
    }
    try {
      await repo.saveRawValue(key, encoded);
    } catch (e) {
      metaLog.w('persistAuxRow($key) failed: $e');
    }
  }

  // ── AUX row domains ─────────────────────────────────────────────────────
  //
  // Each prefixed domain lives OUTSIDE the `app.%` wipe scope enforced by
  // [SettingsDao.replaceAllValues], so its rows survive every full-state
  // snapshot. The backing AppState/BackgroundPlaybackState fields are
  // JsonKey-excluded, making these rows their only persistence route;
  // gate-OFF runs degrade to the code defaults and DefVisibility hides the
  // rows. All domains share the SAME save/load shape, so they route through
  // [_saveAux] / [_loadAux] — adding a domain is one prefix + two wrappers.

  /// Row-key prefix of the dial-ring styling domain.
  static const String kDialRingRowPrefix = 'dialring.';

  /// Row-key prefix of the browse-media-scope domain (`browse.mediaScope`).
  static const String kBrowseRowPrefix = 'browse.';

  /// Row-key prefix of the playback-resume domain (`playback.resumeOnStartup`).
  static const String kPlaybackRowPrefix = 'playback.';

  /// Row-key prefix of the PotPlayer-style keyboard OSD domain (`osd.*`).
  static const String kOsdRowPrefix = 'osd.';

  /// Row-key prefix of the desktop window/playlist-dock domain (`window.*`).
  static const String kWindowRowPrefix = 'window.';

  /// Row-key prefix of the desktop keybind customization domain (`keybind.*`).
  static const String kKeybindRowPrefix = 'keybind.';

  /// Row-key prefix of the video display-mode domain (`video.*`).
  static const String kVideoRowPrefix = 'video.';

  /// Row-key prefix of the sideway-panel domain (`slider.*`).
  static const String kSliderRowPrefix = 'slider.';

  /// Row-key prefix of the shared keyboard-form geometry domain (`form.*`).
  static const String kFormRowPrefix = 'form.';

  /// Row-key prefix of the speed-gesture domain (`speed.*`).
  static const String kSpeedRowPrefix = 'speed.';

  /// Row-key prefix of the virtual-media domain (`virtualmedia.*`).
  static const String kVirtualMediaRowPrefix = 'virtualmedia.';

  /// Row-key prefix of the screenshot save-dir domain (`screenshot.*`).
  static const String kScreenshotRowPrefix = 'screenshot.';

  /// Row-key prefix of the 副音 playback preference domain (`bg.*`).
  ///
  /// Sub-keys used today: `keepWarm`, `alignDefault`, `applyScope`,
  /// `scopePersist`, `ratioEnabled`, `ratioExplicitSave`, `ratioScope`,
  /// `useSavedMapping`, `ratioItem.<mediaKey>`, `progress.<mediaKey>`.
  static const String kBgRowPrefix = 'bg.';

  /// Upserts one `<prefix><field>` row (already ValueCodec-encoded).
  static Future<void> _saveAux(
      String prefix, String field, String encoded) async {
    if (!_ready) return;
    if (!_writeAllowed) return;
    try {
      await repo.saveRawValue('$prefix$field', encoded);
    } catch (e) {
      metaLog.w('saveAuxRow($prefix$field) failed: $e');
    }
  }

  /// Loads every `<prefix>` row keyed by its bare field name.
  /// Malformed values stay raw — decoding/clamping is the caller's concern.
  static Future<Map<String, String>> _loadAux(String prefix) async {
    if (!_ready) return const <String, String>{};
    try {
      final raw = await repo.loadRawValues();
      return <String, String>{
        for (final e in raw.entries)
          if (e.key.startsWith(prefix)) e.key.substring(prefix.length): e.value,
      };
    } catch (e) {
      metaLog.w('loadAuxRows($prefix) failed: $e');
      return const <String, String>{};
    }
  }

  /// ONE table read shared by every AUX domain at boot.
  ///
  /// Rehydrating flag-by-flag used to call `repo.loadRawValues()` once per
  /// domain (11 full scans of `setting_values`). AppStore's cascade now loads
  /// the table once and slices locally via [sliceAux]. Null = module not ready
  /// or read failed (callers degrade exactly like `_loadAux`'s empty map).
  static Future<Map<String, String>?> loadAllRows() async {
    if (!_ready) return null;
    try {
      return await repo.loadRawValues();
    } catch (e) {
      metaLog.w('loadAllRows failed: $e');
      return null;
    }
  }

  /// Pure slice of [all] to `<prefix>` keys as bare field names — the same
  /// shape `loadXRows` returns, without touching the database.
  static Map<String, String> sliceAux(Map<String, String> all, String prefix) {
    final out = <String, String>{};
    for (final e in all.entries) {
      if (e.key.startsWith(prefix)) {
        out[e.key.substring(prefix.length)] = e.value;
      }
    }
    return out;
  }

  static Future<void> saveDialRingRow(String field, String encoded) =>
      _saveAux(kDialRingRowPrefix, field, encoded);
  static Future<Map<String, String>> loadDialRingRows() =>
      _loadAux(kDialRingRowPrefix);

  static Future<void> saveBrowseRow(String field, String encoded) =>
      _saveAux(kBrowseRowPrefix, field, encoded);
  static Future<Map<String, String>> loadBrowseRows() =>
      _loadAux(kBrowseRowPrefix);

  static Future<void> savePlaybackRow(String field, String encoded) =>
      _saveAux(kPlaybackRowPrefix, field, encoded);
  static Future<Map<String, String>> loadPlaybackRows() =>
      _loadAux(kPlaybackRowPrefix);

  static Future<void> saveOsdRow(String field, String encoded) =>
      _saveAux(kOsdRowPrefix, field, encoded);
  static Future<Map<String, String>> loadOsdRows() => _loadAux(kOsdRowPrefix);

  static Future<void> saveWindowRow(String field, String encoded) =>
      _saveAux(kWindowRowPrefix, field, encoded);
  static Future<Map<String, String>> loadWindowRows() =>
      _loadAux(kWindowRowPrefix);

  static Future<void> saveKeybindRow(String field, String encoded) =>
      _saveAux(kKeybindRowPrefix, field, encoded);
  static Future<Map<String, String>> loadKeybindRows() =>
      _loadAux(kKeybindRowPrefix);

  static Future<void> saveVideoRow(String field, String encoded) =>
      _saveAux(kVideoRowPrefix, field, encoded);
  static Future<Map<String, String>> loadVideoRows() =>
      _loadAux(kVideoRowPrefix);

  static Future<void> saveSliderRow(String field, String encoded) =>
      _saveAux(kSliderRowPrefix, field, encoded);
  static Future<Map<String, String>> loadSliderRows() =>
      _loadAux(kSliderRowPrefix);

  static Future<void> saveFormRow(String field, String encoded) =>
      _saveAux(kFormRowPrefix, field, encoded);
  static Future<Map<String, String>> loadFormRows() =>
      _loadAux(kFormRowPrefix);

  static Future<void> saveSpeedRow(String field, String encoded) =>
      _saveAux(kSpeedRowPrefix, field, encoded);
  static Future<Map<String, String>> loadSpeedRows() =>
      _loadAux(kSpeedRowPrefix);

  static Future<void> saveVirtualMediaRow(String field, String encoded) =>
      _saveAux(kVirtualMediaRowPrefix, field, encoded);
  static Future<Map<String, String>> loadVirtualMediaRows() =>
      _loadAux(kVirtualMediaRowPrefix);

  static Future<void> saveScreenshotRow(String field, String encoded) =>
      _saveAux(kScreenshotRowPrefix, field, encoded);
  static Future<Map<String, String>> loadScreenshotRows() =>
      _loadAux(kScreenshotRowPrefix);

  static Future<void> saveBgRow(String field, String encoded) =>
      _saveAux(kBgRowPrefix, field, encoded);
  static Future<Map<String, String>> loadBgRows() => _loadAux(kBgRowPrefix);

  /// Persists a FULL state snapshot as rows (metadata write path).
  ///
  /// Whole-snapshot replacement: use for gate transitions, imports and the
  /// unknown-baseline fallback. Regular mutations should prefer
  /// [persistChangedRows], which only upserts the diff.
  ///
  /// NOTE: no gate-on guard here — the OFF transition itself must land as a
  /// 'false' row, otherwise a restart would silently re-enable.
  ///
  /// Returns true when the rows landed (or there was nothing to write).
  /// Returns false when the DB rejected the write: the caller MUST then treat
  /// its diff baseline as stale, otherwise the fields it tried to write are
  /// silently missing from the mirror forever (the next diff would not
  /// contain them any more).
  static Future<bool> persistState(dynamic appliedState) async {
    if (!_ready || appliedState == null) return true;
    try {
      await repo.replaceAllRawEntries(
        StateBridge.encodeRows(appliedState)
            .entries
            .map((e) => SettingValuesTableCompanion.insert(
                  key: e.key,
                  value: e.value,
                ))
            .toList(),
      );
      return true;
    } catch (e) {
      metaLog.w('persistState failed: $e');
      return false;
    }
  }

  /// Upserts ONLY the rows whose value changed in [changed] (metadata write
  /// path).
  ///
  /// The caller (AppStore) diffs the new snapshot against the last persisted
  /// one, so a single setting toggle writes ONE row on the UI isolate instead
  /// of delete+reinserting the whole `app.*` namespace.
  ///
  /// Returns true when the rows landed (or there was nothing to write).
  /// Returns false when the DB rejected the write — the caller MUST keep its
  /// diff baseline unchanged, so the failed fields are retried by the next
  /// diff instead of disappearing from the mirror.
  static Future<bool> persistChangedRows(Map<String, String> changed) async {
    if (!_ready || changed.isEmpty) return true;
    try {
      await repo.upsertRawValues(
        changed.entries
            .map((e) => SettingValuesTableCompanion.insert(
                  key: e.key,
                  value: e.value,
                ))
            .toList(),
      );
      return true;
    } catch (e) {
      metaLog.w('persistChangedRows failed: $e');
      return false;
    }
  }
}
