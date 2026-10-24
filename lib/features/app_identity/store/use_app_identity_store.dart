import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/app_identity/model/domain/app_identity_entry.dart';
import 'package:iris/features/app_identity/services/app_identity_paths.dart';
import 'package:iris/features/app_identity/services/app_identity_validation.dart';
import 'package:iris/features/app_identity/services/identity_persistence.dart';
import 'package:iris/features/app_identity/store/app_identity_state.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.appIdentity);

/// Store for custom desktop entries (app-identity feature).
///
/// Persistence goes through metadata-settings AUX rows (`identity.*`) —
/// the same route as `tagplay.*`: single-key upserts outside the `app.%`
/// snapshot wipe scope, so entries survive settings snapshots and are
/// entirely absent in legacy mode.
class AppIdentityStore extends Store<AppIdentityState> {
  /// AUX-row prefix of per-entry JSON payloads (`identity.entry.<id>`).
  static const String entryRowPrefix = 'identity.entry.';

  static const String _activeRowKey = 'identity.activeEntry';

  /// Persistence seam; production routes through meta-settings.
  final IdentityPersistence _persistence;

  AppIdentityStore({IdentityPersistence? persistence})
      : _persistence = persistence ?? const MetaIdentityPersistence(),
        super(const AppIdentityState());

  /// True once [load] completed successfully.
  ///
  /// Empty [state.entries] is a legitimate state (no desktop entries), but a
  /// FAILED load leaves the list equally empty. Startup maintenance that
  /// deletes things based on "which entry points at this row" must be able to
  /// tell the two apart ([WorkspaceGc.sweepAtStartup] skips on a failed load,
  /// because its purge is irreversible). Monotonic: a later failure keeps a
  /// previously loaded list in place, so it stays safe to sweep.
  bool _loaded = false;
  bool get loaded => _loaded;

  /// Restores persisted entries + active-entry flag. Safe to call
  /// repeatedly; failures degrade to an empty feature.
  Future<void> load() async {
    try {
      final rows = await _persistence.loadAll();

      final entries = <AppIdentityEntry>[];
      for (final e in rows.entries) {
        if (!e.key.startsWith(entryRowPrefix)) continue;
        try {
          final json = jsonDecode(e.value);
          if (json is Map<String, dynamic>) {
            entries.add(_migrateLegacyBinding(AppIdentityEntry.fromJson(json), json));
          }
        } catch (_) {
          // A malformed entry row must not break loading of the others.
          _log.w('skipping malformed identity row: ${e.key}');
        }
      }
      entries.sort((a, b) => (a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0)));

      final activeRaw = rows[_activeRowKey];
      final active =
          (activeRaw == null || activeRaw.isEmpty) ? null : activeRaw;

      set(state.copyWith(entries: entries, activeEntryId: active));
      _loaded = true;
    } catch (e) {
      _log.e('AppIdentityStore.load failed: $e');
    }
  }

  /// One-time migration of the retired live-binding fields: the old
  /// `scenarioId`/`tagId` become the entry's one-time seed so its existing
  /// saved position survives; `sharedWithDefault` defaults to independent.
  ///
  /// Idempotent — once the entry is rewritten (upsert) the legacy keys are
  /// gone, and the seed fields are read directly.
  AppIdentityEntry _migrateLegacyBinding(
    AppIdentityEntry entry,
    Map<String, dynamic> json,
  ) {
    if (entry.seedScenarioId != null || entry.seedTagId != null) return entry;
    final legacyScenario = json['scenarioId'];
    final legacyTag = json['tagId'];
    final scenarioId = legacyScenario is String && legacyScenario.isNotEmpty
        ? legacyScenario
        : null;
    final tagId = legacyTag is int ? legacyTag : null;
    if (scenarioId == null && tagId == null) return entry;
    return entry.copyWith(seedScenarioId: scenarioId, seedTagId: tagId);
  }

  /// Inserts or updates one entry. The name is validated first — invalid
  /// names throw [ArgumentError] so editor UI surfaces them early instead
  /// of persisting a broken label.
  Future<void> upsertEntry(AppIdentityEntry entry) async {
    final name = AppIdentityValidation.normalizeName(entry.name);
    final problem = AppIdentityValidation.validateName(name);
    if (problem != null) {
      throw ArgumentError.value(name, 'name', problem);
    }
    final fixed = entry.copyWith(
      name: name,
      updatedAt: entry.updatedAt ?? DateTime.now(),
    );

    final next = [...state.entries]
      ..removeWhere((e) => e.id == fixed.id)
      ..add(fixed)
      ..sort((a, b) => (a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0)));
    set(state.copyWith(entries: next));

    try {
      await _persistence.saveRow(
        '$entryRowPrefix${fixed.id}',
        jsonEncode(fixed.toJson()),
      );
    } catch (e) {
      _log.e('upsertEntry persist failed: $e');
    }
  }

  /// Removes one entry. Clearing the active flag alongside prevents a
  /// dangling pointer to a shortcut that no longer exists.
  Future<void> deleteEntry(String id) async {
    final next = [...state.entries]..removeWhere((e) => e.id == id);
    final wasActive = state.activeEntryId == id;
    set(state.copyWith(
      entries: next,
      activeEntryId: wasActive ? null : state.activeEntryId,
    ));
    try {
      await _persistence.saveRow('$entryRowPrefix$id', '');
    } catch (e) {
      _log.e('deleteEntry persist failed: $e');
    }
    if (wasActive) {
      await setActiveEntry(null);
    }
  }

  AppIdentityEntry? entryById(String id) {
    for (final e in state.entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Best-effort deletion of the prepared icon + source files behind
  /// [entry]. Called after an entry is replaced (old image/source superseded)
  /// or deleted, so documents/identity/ does not accumulate stale payloads.
  /// Non-fatal: a leftover file is harmless clutter.
  static Future<void> deleteFilesFor(AppIdentityEntry entry) async {
    await _deleteIfExists(entry.imageRef);
    await _deleteIfExists(entry.sourcePath);
  }

  static Future<void> _deleteIfExists(String ref) async {
    if (ref.isEmpty) return;
    final f = File(AppIdentityPaths.filePath(ref));
    if (f.path.isEmpty) return;
    try {
      if (await f.exists()) await f.delete();
    } catch (e) {
      _log.w('identity file cleanup failed for $ref: $e');
    }
  }

  /// Marks which entry currently owns the SystemPlaying workspace.
  /// Null returns the app to default mode.
  Future<void> setActiveEntry(String? id) async {
    set(state.copyWith(activeEntryId: id));
    try {
      await _persistence.saveRow(_activeRowKey, id ?? '');
    } catch (e) {
      _log.e('setActiveEntry persist failed: $e');
    }
  }

  /// Capability probe result (not persisted — re-probed every launch).
  Future<void> setSupported(bool value) async {
    set(state.copyWith(supported: value));
  }
}

AppIdentityStore useAppIdentityStore() => create(() => AppIdentityStore());
