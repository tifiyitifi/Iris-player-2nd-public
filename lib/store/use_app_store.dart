import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/meta_settings/data/value_codec.dart';
import 'package:iris/utils/app_paths.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/features/meta_settings/engine/effects_registry.dart';
import 'package:iris/features/meta_settings/engine/engine_host.dart';
import 'package:iris/features/meta_settings/engine/persist_policy.dart';
import 'package:iris/features/meta_settings/bridge/state_bridge.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/meta_settings/model/enum/setting_value_type.dart';
import 'package:iris/models/db/app_database.dart'
    show SettingValuesTableCompanion;
import 'package:iris/models/enums/breadcrumb_start_side.dart'
    show BreadcrumbStartSide;
import 'package:iris/models/enums/step_seek_mode.dart' show StepSeekMode;
import 'package:iris/models/enums/video_cache_preset.dart';
import 'package:iris/models/enums/webdav_scan_mode.dart' show WebDavScanMode;
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart'
    show clampPageSize;
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_ring_dial_math.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_queue_layout.dart'
    show ScenarioQueueLayout, nextScenarioQueueLayout;
import 'package:iris/features/scenario_playback/model/enum/scenario_queue_profile.dart'
    show ScenarioQueueProfile, ScenarioQueueProfileRows, ScenarioQueueProfileState;
import 'package:iris/features/speed/model/enum/speed_gesture_mode.dart'
    show SpeedGestureMode;
import 'package:iris/features/speed/model/enum/speed_rate_picker_mode.dart'
    show SpeedRatePickerMode;
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart'
    show VmCrossSegmentDragStrategy, VmDualTimeSyncMode;
import 'package:iris/features/virtual_media/rule/vm_tick_color.dart'
    show sanitizeVmTickColorArgb;
import 'package:iris/features/virtual_media/rule/vm_tick_extent.dart'
    show kVmTickExtentMaxPx, kVmTickExtentMinPx, sanitizeVmTickExtentPx;
import 'package:iris/features/tag_play/playback/tag_play_controller.dart';
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_dock.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/keyboard_form_geometry.dart';
import 'package:iris/models/store/gesture/gesture_region_layout.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/models/store/gesture_region.dart';
import 'package:iris/pages/player/overlays/gesture_region_editor/gesture_editor_models.dart'
    show dropNonGridLayouts, tapLayoutHasToggle;
import 'package:iris/models/store/title_overlay_config.dart';
import 'package:iris/models/store/video_display_mode.dart';
import 'package:iris/models/store/window_fit_mode.dart';
import 'package:iris/store/persistent_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/widgets/popup.dart' show PopupDirection;

final areaKeyLog = AreaKeyLog(LogKeys.legacyStore);
final gestureAreaKeyLog = AreaKeyLog(LogKeys.legacyGesture);

/// Canonical `virtualmedia.` row fields (DB向Def看齐): the bare field matches
/// the SettingDef key suffix (`virtualmedia.<field>`), so generic def↔row
/// tooling (parity/export/doc) works without per-row exceptions.
@visibleForTesting
const Map<String, String> kVmCanonicalToLegacyField = {
  'crossDragStrategy': 'vmCrossSegmentDragStrategy',
  'dualTimeSync': 'vmDualTimeSync',
  'hideChunkWhenSingleSegment': 'vmHideChunkWhenSingleSegment',
  'markTickColor': 'vmMarkTickColor',
  'markTickExtent': 'vmMarkTickExtent',
};

/// Reads the canonical field, falling back to the legacy `vm*` field once.
/// Returns null when neither is present. Pure: fully unit-testable.
@visibleForTesting
String? resolveVmRowValue(
    Map<String, String> rows, String canonical, String legacy) {
  final v = rows[canonical];
  if (v != null) return v;
  return rows[legacy];
}

/// Engine contract: AppStore is the production [SettingsEngineHost]. The
/// engine (metadata rows, tooling) and the typed mutators below converge on
/// the same persistence tail — [_persist] — which is what makes dialog-driven
/// edits and metadata-row edits indistinguishable to storage.
class AppStore extends PersistentStore<AppState> implements SettingsEngineHost {
  AppStore() : super(AppState());

  /// Last full `app.*` row set this store wrote (or adopted at load), used to
  /// diff a metadata mutation down to a single-row upsert. Null = baseline
  /// unknown, so the next rows write falls back to a full snapshot replace.
  Map<String, String>? _lastPersistedRows;

  Future<void> updateAutoPlay(bool autoPlay) async =>
      set(state.copyWith(autoPlay: autoPlay));

  Future<void> updateShuffle(bool shuffle) async {
    set(state.copyWith(shuffle: shuffle));
    await _persist(state);
  }

  Future<void> updateRepeat(Repeat repeat) async {
    set(state.copyWith(repeat: repeat));
    await _persist(state);
  }

  Future<void> toggleRepeat() async {
    switch (state.repeat) {
      case Repeat.none:
        set(state.copyWith(repeat: Repeat.one));
        break;
      case Repeat.one:
        set(state.copyWith(repeat: Repeat.all));
        break;
      case Repeat.all:
        set(state.copyWith(repeat: Repeat.none));
        break;
    }
    await _persist(state);
  }

  Future<void> updateFit(BoxFit fit) async {
    set(state.copyWith(fit: fit));
    await _persist(state);
  }

  Future<void> toggleFit() async {
    switch (state.fit) {
      case BoxFit.contain:
        set(state.copyWith(fit: BoxFit.fill));
        break;
      case BoxFit.fill:
        set(state.copyWith(fit: BoxFit.cover));
        break;
      case BoxFit.cover:
        set(state.copyWith(fit: BoxFit.none));
        break;
      case BoxFit.none:
        set(state.copyWith(fit: BoxFit.contain));
        break;
      default:
        break;
    }
    await _persist(state);
  }

  Future<void> updateTransientRate(double value) async {
    areaKeyLog.i('transientRate: $value');
    set(state.copyWith(transientRate: value));
    await _persist(state);
  }

  Future<void> updatePlaybackRateBeforeTransient(double value) async {
    areaKeyLog.i('playbackRateBeforeTransient: $value');
    set(state.copyWith(playbackRateBeforeTransient: value));
    await _persist(state);
  }

  /// Pure rate-change transition shared by [updateRate] and tests: any
  /// explicit non-1.0 rate becomes the Z-key restore memory, so X/C keys,
  /// menus and gestures all keep `rateBeforeReset` pointing at the most
  /// recent custom speed regardless of source.
  static AppState applyRateChange(AppState state, double value) {
    if (value != 1.0 && state.rateBeforeReset != value) {
      return state.copyWith(rate: value, rateBeforeReset: value);
    }
    return state.copyWith(rate: value);
  }

  Future<void> updateRate(double value) async {
    areaKeyLog.i('updateRate: $value');
    set(AppStore.applyRateChange(state, value));
    await _persist(state);
  }

  /// Whether [updateRateLive] changed the rate without persisting it.
  bool _rateDirty = false;

  /// Live-only rate update for high-frequency adjusters (the held X/C keys):
  /// refreshes the UI immediately but does NOT touch storage. A held key fires
  /// ~30×/s, and each `_persist` re-encodes the whole AppState and rewrites
  /// every settings row — doing that per repeat janks the UI. Persist once via
  /// [commitRate] when the key is released.
  void updateRateLive(double value) {
    final next = AppStore.applyRateChange(state, value);
    if (next.rate == state.rate &&
        next.rateBeforeReset == state.rateBeforeReset) {
      return;
    }
    _rateDirty = true;
    set(next);
  }

  /// Flushes a pending live rate change to storage (no-op when clean).
  Future<void> commitRate() async {
    if (!_rateDirty) return;
    _rateDirty = false;
    await _persist(state);
  }

  /// Discards a modal picker's preview in one step.
  ///
  /// The preview runs through [updateRateLive], which never reaches storage,
  /// so an in-memory rollback is the whole job — and it must restore
  /// `rateBeforeReset` too, because [applyRateChange] rewrites that on every
  /// non-1.0 write and would otherwise leak the previewed speed into the
  /// Z-key restore memory.
  void rollbackRatePreview({
    required double rate,
    required double rateBeforeReset,
  }) {
    if (!_rateDirty &&
        state.rate == rate &&
        state.rateBeforeReset == rateBeforeReset) {
      return;
    }
    _rateDirty = false;
    set(state.copyWith(rate: rate, rateBeforeReset: rateBeforeReset));
  }

  @override
  Future<void> dispose() async {
    // A held X/C mutates only memory; if the app tears down before the KeyUp
    // (or the KeyUp was swallowed by a dialog), flush it so the DB row keeps
    // the user's last speed instead of reverting on next launch.
    await commitRate();
    await super.dispose();
  }

  /// Applies the desktop Z-key speed-reset toggle result atomically
  /// (new rate + its memory) — see resolveSpeedResetToggle.
  Future<void> applySpeedReset(double rate, double memory) async {
    areaKeyLog.i('applySpeedReset: $rate (memory: $memory)');
    set(state.copyWith(rate: rate, rateBeforeReset: memory));
    await _persist(state);
  }

  Future<void> updateVolume(int volume) async {
    set(state.copyWith(
        volume: volume < 0
            ? 0
            : volume > 100
                ? 100
                : volume));
    await _persist(state);
  }

  Future<void> updateSeekStepSeconds(int seconds) async {
    final int next = seconds.clamp(1, 120);
    if (next == state.seekStepSeconds) return; // no-op at the range bounds
    set(state.copyWith(seekStepSeconds: next));
    _seekStepDirty = false; // this path persisted directly
    await _persist(state);
  }

  /// Whether [updateSeekStepSecondsLive] changed the value without persisting.
  bool _seekStepDirty = false;

  /// Live-only seek-step update for high-frequency adjusters (the popover's
  /// held ↑/↓ keys and its strip drag): refreshes the UI immediately but does
  /// NOT touch storage. A held key fires ~30×/s, and each `_persist` re-encodes
  /// the whole AppState and rewrites every settings row — doing that per repeat
  /// janks the UI. Persist once via [commitSeekStepSeconds] when the gesture or
  /// key ends.
  void updateSeekStepSecondsLive(int seconds) {
    final int next = seconds.clamp(1, 120);
    if (next == state.seekStepSeconds) return;
    _seekStepDirty = true;
    set(state.copyWith(seekStepSeconds: next));
  }

  /// Flushes a pending live seek-step change to storage (no-op when clean).
  Future<void> commitSeekStepSeconds() async {
    if (!_seekStepDirty) return;
    _seekStepDirty = false;
    await _persist(state);
  }

  Future<void> updateKeyboardShortcutScheme(
      KeyboardShortcutScheme scheme) async {
    set(state.copyWith(keyboardShortcutScheme: scheme));
    await _persist(state);
  }

  /// Marks a suppressible warning as "don't show again" (idempotent).
  Future<void> suppressWarning(String id) async {
    if (state.suppressedWarnings.contains(id)) return;
    set(state.copyWith(
      suppressedWarnings: [...state.suppressedWarnings, id],
    ));
    await _persist(state);
  }

  /// Settings-panel reset: every suppressible warning shows again.
  Future<void> resetSuppressedWarnings() async {
    if (state.suppressedWarnings.isEmpty) return;
    set(state.copyWith(suppressedWarnings: []));
    await _persist(state);
  }

  /// Re-enables a single warning from the settings panel.
  Future<void> resetWarning(String id) async {
    if (!state.suppressedWarnings.contains(id)) return;
    set(state.copyWith(
      suppressedWarnings:
          state.suppressedWarnings.where((w) => w != id).toList(),
    ));
    await _persist(state);
  }

  // Drag-time sliders publish to memory only (`persist: false`) and commit
  // ONCE on `onChangeEnd`. Persisting per tick hammered the UI-isolate Drift
  // (and, for scale/percent, rewrote the whole app.* snapshot + blob) on every
  // phone frame. See also [persistSidewayPanelGeometry].
  Future<void> updateCircleLandscapePercent(int clPercent,
      {bool persist = true}) async {
    set(state.copyWith(
        circleLandscapePercent: clPercent < 30
            ? 30
            : clPercent > 90
                ? 90
                : clPercent));
    if (persist) await _persist(state);
  }

  Future<void> updateCircleSliderScale(double v, {bool persist = true}) async {
    set(state.copyWith(circleSliderScale: v.clamp(0.0, 1.0)));
    if (persist) await _persist(state);
  }

  Future<void> updateCirclePosX(double v, {bool persist = true}) async {
    final double v2 = v.clamp(0.0, 1.0).toDouble();
    set(state.copyWith(circlePosX: v2));
    if (persist)
      await _saveSliderRow('circlePosX', v2, SettingValueType.double);
  }

  Future<void> updateCirclePosY(double v, {bool persist = true}) async {
    final double v2 = v.clamp(0.0, 1.0).toDouble();
    set(state.copyWith(circlePosY: v2));
    if (persist)
      await _saveSliderRow('circlePosY', v2, SettingValueType.double);
  }

  /// Side panel bottom button-block position (side-relative 0..1, 0 = the edge
  /// facing the screen centre). Persisted as the `slider.barPos` AUX row, the
  /// same lightweight path [updateCirclePosX] uses.
  Future<void> updateSidewayBarPos(double v, {bool persist = true}) async {
    final double v2 = v.clamp(0.0, 1.0).toDouble();
    set(state.copyWith(sidewayBarPos: v2));
    if (persist) await _saveSliderRow('barPos', v2, SettingValueType.double);
  }

  // ── Ring dial styling ────────────────────────────────────────────────────
  // Persisted EXCLUSIVELY as `dialring.` Drift rows (never the JSON blob nor
  // the app.% snapshot — the fields are JsonKey-excluded). Gate OFF keeps
  // edits memory-only: the styling surface is metadata-mode-only by design.

  Future<void> _saveDialRow(
      String field, Object? value, SettingValueType type) async {
    if (!state.useMetadataSettings || !MetaSettingsModule.ready) return;
    final String? encoded = ValueCodec.encode(type, value);
    if (encoded == null) return;
    await MetaSettingsModule.saveDialRingRow(field, encoded);
  }

  Future<void> updateRingDialPalette(RingDialPalette palette) async {
    set(state.copyWith(ringDialPalette: palette));
    await _saveDialRow(
        'ringDialPalette', palette.name, SettingValueType.enumeration);
  }

  Future<void> updateRingDialHeightPct(double v, {bool persist = true}) async {
    final double pct = clampRingDialPct(v);
    set(state.copyWith(ringDialHeightPct: pct));
    if (persist) {
      await _saveDialRow('ringDialHeightPct', pct, SettingValueType.double);
    }
  }

  Future<void> updateRingDialSide(DialSide side) async {
    set(state.copyWith(ringDialSide: side));
    await _saveDialRow('ringDialSide', side.name, SettingValueType.enumeration);
  }

  Future<void> updateRingDialAssignment(RingDialAssignment assignment) async {
    set(state.copyWith(ringDialAssignment: assignment));
    await _saveDialRow(
        'ringDialAssignment', assignment.name, SettingValueType.enumeration);
  }

  Future<void> updateRingDialHideChunkWhenUnchunked(bool hide) async {
    set(state.copyWith(ringDialHideChunkWhenUnchunked: hide));
    await _saveDialRow(
        'ringDialHideChunkWhenUnchunked', hide, SettingValueType.bool);
  }

  /// Virtual media: clamp the progress-ring drag inside the current file.
  Future<void> updateRingDialVmProgressLock(bool lock) async {
    set(state.copyWith(ringDialVmProgressLock: lock));
    await _saveDialRow('ringDialVmProgressLock', lock, SettingValueType.bool);
  }

  @Deprecated('Use updateRingDialHideChunkWhenUnchunked')
  Future<void> updateRingDialHideInnerWhenUnchunked(bool hide) =>
      updateRingDialHideChunkWhenUnchunked(hide);

  Future<void> updateRingDialRingSlotT(double v, {bool persist = true}) async {
    final double t = clampSlotT(v);
    set(state.copyWith(ringDialRingSlotT: t));
    if (persist) {
      await _saveDialRow('ringDialRingSlotT', t, SettingValueType.double);
    }
  }

  Future<void> updateSidePanelDialogOffset(Offset offset) async {
    final Offset clamped = Offset(
      offset.dx.clamp(0.05, 0.95).toDouble(),
      offset.dy.clamp(0.05, 0.95).toDouble(),
    );
    set(state.copyWith(sidePanelDialogOffset: clamped));
    // Persist as "x,y" string via slider AUX row (lightweight, no new table).
    final String encoded = '${clamped.dx},${clamped.dy}';
    final String? enc = ValueCodec.encode(SettingValueType.string, encoded);
    if (enc == null) return;
    if (!state.useMetadataSettings || !MetaSettingsModule.ready) return;
    await MetaSettingsModule.saveSliderRow('dialogOffset', enc);
  }

  // ── Virtual media (metadata era) ───────────────────────────────────────
  Future<void> _saveVirtualMediaRow(
      String field, Object? value, SettingValueType type) async {
    if (!state.useMetadataSettings || !MetaSettingsModule.ready) return;
    final String? encoded = ValueCodec.encode(type, value);
    if (encoded == null) return;
    await MetaSettingsModule.saveVirtualMediaRow(field, encoded);
  }

  Future<void> updateVmCrossSegmentDragStrategy(
      VmCrossSegmentDragStrategy v) async {
    set(state.copyWith(vmCrossSegmentDragStrategy: v));
    await _saveVirtualMediaRow(
        'crossDragStrategy', v.name, SettingValueType.enumeration);
  }

  /// B-scheme dual-time second-grid alignment. Display-only; applied live.
  Future<void> updateVmDualTimeSync(VmDualTimeSyncMode v) async {
    set(state.copyWith(vmDualTimeSync: v));
    await _saveVirtualMediaRow(
        'dualTimeSync', v.name, SettingValueType.enumeration);
  }

  Future<void> updateVmHideChunkWhenSingleSegment(bool v) async {
    set(state.copyWith(vmHideChunkWhenSingleSegment: v));
    await _saveVirtualMediaRow(
        'hideChunkWhenSingleSegment', v, SettingValueType.bool);
  }

  Future<void> updateVmMarkTickColor(int v) async {
    // Alpha stays locked at FF: translucent ticks vanish on the axis.
    final int opaque = v | 0xFF000000;
    set(state.copyWith(vmMarkTickColor: opaque));
    await _saveVirtualMediaRow('markTickColor', opaque, SettingValueType.int);
  }

  Future<void> updateVmMarkTickExtent(int v) async {
    final int clamped = v.clamp(kVmTickExtentMinPx, kVmTickExtentMaxPx).toInt();
    set(state.copyWith(vmMarkTickExtent: clamped));
    await _saveVirtualMediaRow('markTickExtent', clamped, SettingValueType.int);
  }

  // ── Browse media scope ──────────────────────────────────────────────────
  // Persisted EXCLUSIVELY as a `browse.` Drift row (JsonKey-excluded state
  // field — see app_state.dart). Gate OFF keeps edits memory-only; browsing
  // surfaces resolve through resolveBrowseMediaScope and degrade to `all`.

  Future<void> _saveBrowseRow(
      String field, Object? value, SettingValueType type) async {
    if (!state.useMetadataSettings || !MetaSettingsModule.ready) return;
    final String? encoded = ValueCodec.encode(type, value);
    if (encoded == null) return;
    await MetaSettingsModule.saveBrowseRow(field, encoded);
  }

  Future<void> updateBrowseMediaScope(BrowseMediaScope scope) async {
    set(state.copyWith(browseMediaScope: scope));
    await _saveBrowseRow(
        'mediaScope', scope.name, SettingValueType.enumeration);
  }

  // ── Resume on startup ───────────────────────────────────────────────────
  // Persisted EXCLUSIVELY as a `playback.` Drift row (JsonKey-excluded state
  // field — see app_state.dart). Gate OFF keeps edits memory-only; the
  // startup resume resolves through resolveResumeOnStartup and degrades to
  // `true`. NEVER persist through the app.% snapshot: the loader force-
  // normalizes the session flag `autoPlay`, and this policy must survive
  // independently of it.

  Future<void> _savePlaybackRow(
      String field, Object? value, SettingValueType type) async {
    if (!state.useMetadataSettings || !MetaSettingsModule.ready) return;
    final String? encoded = ValueCodec.encode(type, value);
    if (encoded == null) return;
    await MetaSettingsModule.savePlaybackRow(field, encoded);
  }

  Future<void> updateResumeOnStartup(bool value) async {
    set(state.copyWith(resumeOnStartup: value));
    await _savePlaybackRow('resumeOnStartup', value, SettingValueType.bool);
  }

  /// Sets the desktop drag-drop append-zone share (percent of the player
  /// height). Hard-clamped to 10–90 to honor the zone contract regardless of
  /// the caller; persisted as a `playback.dropAppendPercent` AUX row.
  Future<void> updateDropAppendZonePercent(double value) async {
    final double clamped = value.clamp(10.0, 90.0).toDouble();
    set(state.copyWith(dropAppendZonePercent: clamped));
    await _savePlaybackRow(
        'dropAppendPercent', clamped, SettingValueType.double);
  }

  /// Sets the media_kit (mpv) demuxer cache sizing preset; persisted as a
  /// `playback.videoCachePreset` AUX row. The player applies it on the next
  /// player init and on every change (see `useMediaKitPlayer`).
  Future<void> updateVideoCachePreset(VideoCachePreset v) async {
    set(state.copyWith(videoCachePreset: v));
    await _savePlaybackRow(
        'videoCachePreset', v.name, SettingValueType.enumeration);
  }

  /// Sets the step-seek (← / →) scheduling strategy; persisted as a
  /// `playback.stepSeekMode` AUX row. The media_kit hook re-reads it live, so a
  /// change takes effect on the next burst without reopening the video.
  Future<void> updateStepSeekMode(StepSeekMode v) async {
    set(state.copyWith(stepSeekMode: v));
    await _savePlaybackRow(
        'stepSeekMode', v.name, SettingValueType.enumeration);
  }

  // ── Keyboard OSD (PotPlayer-style) ──────────────────────────────────────
  // AUX `osd.` rows — JsonKey-excluded, desktop-only, gate-OFF degrades to
  // no OSD / defaults via resolveOsd* helpers.

  Future<void> _saveOsdRow(
      String field, Object? value, SettingValueType type) async {
    if (!state.useMetadataSettings || !MetaSettingsModule.ready) return;
    final String? encoded = ValueCodec.encode(type, value);
    if (encoded == null) return;
    await MetaSettingsModule.saveOsdRow(field, encoded);
  }

  Future<void> updateOsdEnabled(bool value) async {
    set(state.copyWith(osdEnabled: value));
    await _saveOsdRow('osdEnabled', value, SettingValueType.bool);
  }

  Future<void> updateOsdVisibilityMode(OsdVisibilityMode mode) async {
    set(state.copyWith(osdVisibilityMode: mode));
    await _saveOsdRow(
        'osdVisibilityMode', mode.name, SettingValueType.enumeration);
  }

  Future<void> updateOsdHAlign(OsdHAlign v) async {
    set(state.copyWith(osdHAlign: v));
    await _saveOsdRow('osdHAlign', v.name, SettingValueType.enumeration);
  }

  Future<void> updateOsdVAlign(OsdVAlign v) async {
    set(state.copyWith(osdVAlign: v));
    await _saveOsdRow('osdVAlign', v.name, SettingValueType.enumeration);
  }

  Future<void> updateOsdLayout(OsdLayout v) async {
    set(state.copyWith(osdLayout: v));
    await _saveOsdRow('osdLayout', v.name, SettingValueType.enumeration);
  }

  Future<void> updateOsdDurationMs(int v) async {
    final int clamped = v.clamp(800, 5000);
    set(state.copyWith(osdDurationMs: clamped));
    await _saveOsdRow('osdDurationMs', clamped, SettingValueType.int);
  }

  Future<void> updateRingDialOuterRadius(double v,
      {bool persist = true}) async {
    final double outer = clampRingDialOuterRadius(v);
    // Keep the stored inner factor truthful against the new outer bound so
    // slider values never diverge from what renders (store-time clamping).
    final double inner = clampRingDialInnerRadius(
      state.ringDialInnerRadius,
      outerFactor: outer,
    );
    set(state.copyWith(ringDialOuterRadius: outer, ringDialInnerRadius: inner));
    if (persist) {
      await _saveDialRow('ringDialOuterRadius', outer, SettingValueType.double);
      await _saveDialRow('ringDialInnerRadius', inner, SettingValueType.double);
    }
  }

  Future<void> updateRingDialInnerRadius(double v,
      {bool persist = true}) async {
    final double inner =
        clampRingDialInnerRadius(v, outerFactor: state.ringDialOuterRadius);
    set(state.copyWith(ringDialInnerRadius: inner));
    if (persist) {
      await _saveDialRow('ringDialInnerRadius', inner, SettingValueType.double);
    }
  }

  Future<void> updateMute(bool isMuted) async {
    set(state.copyWith(isMuted: isMuted));
    await _persist(state);
  }

  Future<void> toggleMute() async {
    set(state.copyWith(isMuted: !state.isMuted));
    _persist(state);
  }

  Future<void> updateThemeMode(ThemeMode themeMode) async {
    set(state.copyWith(themeMode: themeMode));
    await _persist(state);
  }

  Future<void> updateLanguage(String language) async {
    set(state.copyWith(language: language));
    await _persist(state);
  }

  Future<void> toggleAutoResize() async {
    set(state.copyWith(autoResize: !state.autoResize));
    await _persist(state);
  }

  Future<void> toggleAlwaysPlayFromBeginning() async {
    set(state.copyWith(
        alwaysPlayFromBeginning: !state.alwaysPlayFromBeginning));
    await _persist(state);
  }

  Future<void> updatePlayerBackend(PlayerBackend backend) async {
    set(state.copyWith(playerBackend: backend));
    await _persist(state);
  }

  Future<void> updateWebDavScanMode(WebDavScanMode mode) async {
    set(state.copyWith(webDavScanMode: mode));
    await _persist(state);
  }

  Future<void> updateSortBy(SortBy sortBy) async {
    set(state.copyWith(sortBy: sortBy));
    await _persist(state);
  }

  Future<void> updateSortOrder(SortOrder sortOrder) async {
    set(state.copyWith(sortOrder: sortOrder));
    await _persist(state);
  }

  Future<void> updateFolderFirst(bool folderFirst) async {
    set(state.copyWith(folderFirst: folderFirst));
    await _persist(state);
  }

  Future<void> updateStorageBrowserPageSize(int value) async {
    set(state.copyWith(storageBrowserPageSize: value));
    await _persist(state);
  }

  // Future<void> updateOrientation(ScreenOrientation orientation) async {
  //   set(state.copyWith(orientation: orientation));
  //   await _persist(state);
  // }

  Future<void> updatePreferredOrientation(
      ScreenOrientation preferredOrientation) async {
    set(state.copyWith(preferredOrientation: preferredOrientation));
    await _persist(state);
  }

  Future<void> updateRuntimeOrientation(
      ScreenOrientation runtimeOrientation) async {
    set(state.copyWith(runtimeOrientation: runtimeOrientation));

    if (state.reuseLastOrientation) {
      await _persist(state);
    }
  }

  Future<void> toggleReuseLastRotateOrientation() async {
    set(state.copyWith(reuseLastOrientation: !state.reuseLastOrientation));
    _persist(state);
  }

  /// Writes the legacy circle placement directly.
  ///
  /// The placement is no longer an independent choice: it is the persisted
  /// shadow of [phoneLandscapeUseMode] (see [sliderTypeForUseMode]) and every
  /// UI entry point pairs the two, so this stays for the frozen legacy path
  /// and for tests — a one-sided write here is exactly the drift the pairing
  /// exists to prevent.
  Future<void> updatePhoneLandscapeSlierType(
      PhoneLandscapeSliderType sliderType) async {
    set(state.copyWith(phoneLandscapeSliderType: sliderType));
    await _persist(state);
  }

  /// Writes the one-handed mode AND its paired legacy circle placement in one
  /// state transition.
  ///
  /// The two fields encode the same left/right decision but are persisted
  /// separately (the mode in the legacy blob, the placement in its own blob
  /// key). Writing one without the other is what let them drift: a stale
  /// `circleRight` then steers [resolveControlPanelAnchor] while the settings
  /// dialog reads `normal`. Deriving the placement here — and in the two
  /// anchor setters above — makes the pair inseparable for every caller,
  /// including the ones added later.
  ///
  /// The mode is folded through [PhoneLandscapeUseModeHelper.live] on the way
  /// in: a deprecated member written here would be persisted verbatim and then
  /// read back as NO side, so the hand the user is operating with silently
  /// becomes the other one.
  Future<void> updatePhoneLandscapeUseMode(
      PhoneLandscapeUseMode useMode) async {
    final mode = useMode.live;
    set(state.copyWith(
      phoneLandscapeUseMode: mode,
      phoneLandscapeSliderType: sliderTypeForUseMode(mode),
    ));
    await _persist(state);
  }

  Future<void> updatePhoneOneHandedScrubberKind(
      PhoneOneHandedScrubberKind kind) async {
    set(state.copyWith(phoneOneHandedScrubberKind: kind));
    await _persist(state);
  }

  /// Phone-PORTRAIT bottom-bar alignment of the normal playback group.
  /// Persisted as the `app.portraitPlaybackAlign` snapshot row.
  Future<void> updatePortraitPlaybackAlign(PortraitBarAlign align) async {
    set(state.copyWith(portraitPlaybackAlign: align));
    await _persist(state);
  }

  /// Phone-PORTRAIT bottom-bar alignment of the group-2 副音 quick bar.
  /// Persisted as the `app.portraitSubAudioAlign` snapshot row.
  Future<void> updatePortraitSubAudioAlign(PortraitBarAlign align) async {
    set(state.copyWith(portraitSubAudioAlign: align));
    await _persist(state);
  }

  Future<void> updateSnakeFineWindowSeconds(int seconds) async {
    // Full dial fine-tune range contract: 5 s floor .. 10 min ceiling.
    final int clamped = seconds.clamp(5, 600);
    set(state.copyWith(snakeFineWindowSeconds: clamped));
    await _persist(state);
  }

  /// Writes one center-sector action (see [CenterZone]); the four sectors are
  /// independent generic settings, so a single typed setter keeps the inline
  /// slider-dialog pickers and the metadata rows in sync.
  Future<void> updateCenterZoneAction(
      CenterZone zone, CircleSliderCenterAction action) async {
    set(switch (zone) {
      CenterZone.inward => state.copyWith(centerZoneInwardAction: action),
      CenterZone.outward => state.copyWith(centerZoneOutwardAction: action),
      CenterZone.top => state.copyWith(centerZoneTopAction: action),
      CenterZone.bottom => state.copyWith(centerZoneBottomAction: action),
    });
    await _persist(state);
  }

  Future<void> updateLandscapeGestureProfile(
      LandscapeGestureProfile value) async {
    set(state.copyWith(landscapeGestureProfile: value));
    await _persist(state);
  }

  Future<void> updatePortraitGestureProfile(
      PortraitGestureProfile value) async {
    set(state.copyWith(portraitGestureProfile: value));
    await _persist(state);
  }

  Future<void> toggleShowControlsOnPlayToPause() async {
    set(state.copyWith(
      showControlsOnPlayToPause: !state.showControlsOnPlayToPause,
    ));
    await _persist(state);
  }

  Future<void> updateGestureLayoutProfile(
    String profileKey,
    Map<GestureIntent, GestureLayout> layout,
  ) async {
    final updated = Map<String, Map<GestureIntent, GestureLayout>>.from(
      state.gestureLayoutProfiles,
    );

    updated[profileKey] = layout;

    set(state.copyWith(gestureLayoutProfiles: updated));
    await _persist(state);
  }

  Future<void> updateGestureIntentLayout({
    required String profileKey,
    required GestureIntent intent,
    required GestureLayout layout,
  }) async {
    // Defense in depth behind the editor Dialog: a tap layout with zero
    // `toggleControls` would strand the control bar, so refuse to persist it.
    if (intent == GestureIntent.tap && !tapLayoutHasToggle(layout)) {
      gestureAreaKeyLog
          .e('Refusing tap layout without toggleControls for $profileKey');
      return;
    }
    final profiles = Map<String, Map<GestureIntent, GestureLayout>>.from(
        state.gestureLayoutProfiles);
    final profile = {...(profiles[profileKey] ?? {})};
    profile[intent] = layout;
    profiles[profileKey] = profile;

    set(state.copyWith(gestureLayoutProfiles: profiles));
    await _persist(state);
  }

  // Replace ALL regions for an intent
  Future<void> updateGestureIntentRegions({
    required String profileKey,
    required GestureIntent intent,
    required List<GestureRegion> regions,
  }) async {
    final layouts = Map<String, Map<GestureIntent, GestureLayout>>.from(
        state.gestureLayoutProfiles);

    layouts[profileKey]![intent] =
        GestureLayout(intent: intent, regions: regions);

    set(state.copyWith(gestureLayoutProfiles: layouts));
    await _persist(state);
  }

  /// Profile key whose layout is currently effective — the write-side mirror
  /// of [resolveActiveGestureLayouts]; inline editors commit to this profile.
  String resolveActiveGestureProfileKey(
    AppState state,
    Orientation realOrientation,
  ) {
    final orientation = resolveGestureOrientation(
      state: state,
      realOrientation: realOrientation,
    );
    // Legacy: region layouts live under the shared default key.
    if (!state.useMetadataSettings) {
      return kLayoutRegion;
    }
    return switch (orientation) {
      GestureOrientation.landscape => switch (state.landscapeGestureProfile) {
          LandscapeGestureProfile.region => kLayoutRegion,
          LandscapeGestureProfile.rightSide => kLayoutRegionRightSide,
          LandscapeGestureProfile.leftSide => kLayoutRegionLeftSide,
          // deprecated compat
          LandscapeGestureProfile.rightHand => kLayoutRegionRightSide,
          LandscapeGestureProfile.leftHand => kLayoutRegionLeftSide,
          LandscapeGestureProfile.tagPlay => kLayoutRegion,
          LandscapeGestureProfile.classic => kLayoutRegion,
        },
      GestureOrientation.portrait => kLayoutRegionPortrait,
    };
  }

  Map<GestureIntent, GestureLayout> resolveActiveGestureLayouts(
    AppState state,
    Orientation realOrientation,
  ) {
    gestureAreaKeyLog.i('kLayoutDefault=$kLayoutDefault');
    gestureAreaKeyLog.i('kLayoutRegion=$kLayoutRegion');
    final profileKey = resolveActiveGestureProfileKey(state, realOrientation);
    return state.gestureLayoutProfiles[profileKey] ??
        defaultGestureLayoutProfiles[profileKey]!;
  }

  Map<GestureIntent, GestureLayout> useActiveGestureLayouts(
      BuildContext context) {
    return useAppStore().select(
      context,
      (state) => resolveActiveGestureLayouts(
        state,
        MediaQuery.of(context).orientation,
      ),
    );
  }

  // Change ONE region’s action
  Future<void> updateGestureRegionAction({
    required String profileKey,
    required GestureIntent intent,
    required int regionIndex,
    required GestureAction newAction,
  }) async {
    final layouts = Map<String, Map<GestureIntent, GestureLayout>>.from(
        state.gestureLayoutProfiles);

    assert(layouts.containsKey(profileKey), 'Missing profileKey: $profileKey');
    assert(layouts[profileKey]!.containsKey(intent),
        'Missing intent $intent in $profileKey');

    final layout = layouts[profileKey]![intent]!;

    if (regionIndex < 0 || regionIndex >= layout.regions.length) {
      throw RangeError('Invalid regionIndex $regionIndex for intent $intent');
    }

    final regions = [...layout.regions];

    regions[regionIndex] = regions[regionIndex].copyWith(action: newAction);

    layouts[profileKey]![intent] = layout.copyWith(regions: regions);

    set(state.copyWith(gestureLayoutProfiles: layouts));
    await _persist(state);
  }

  //Reset a profile back to defaults
  Future<void> resetGestureProfile(String profileKey) async {
    final layouts = Map<String, Map<GestureIntent, GestureLayout>>.from(
        state.gestureLayoutProfiles);

    layouts[profileKey] = defaultGestureLayoutProfiles[profileKey]!;

    set(state.copyWith(gestureLayoutProfiles: layouts));
    await _persist(state);
  }

  // a batch version of reset profiles back to defaults
  Future<void> resetGestureProfiles(Set<String> profileKeys) async {
    final layouts = Map<String, Map<GestureIntent, GestureLayout>>.from(
      state.gestureLayoutProfiles,
    );

    for (final key in profileKeys) {
      if (defaultGestureLayoutProfiles.containsKey(key)) {
        layouts[key] = defaultGestureLayoutProfiles[key]!;
      }
    }

    set(state.copyWith(gestureLayoutProfiles: layouts));
    await _persist(state);
  }

  Future<void> resetGestureLayoutsBySelection({
    required Set<String> profileKeys,
    required Set<GestureIntent> intents,
  }) async {
    final layouts = Map<String, Map<GestureIntent, GestureLayout>>.from(
      state.gestureLayoutProfiles,
    );

    for (final profileKey in profileKeys) {
      final defaultProfile = defaultGestureLayoutProfiles[profileKey];
      if (defaultProfile == null) continue;

      final profileLayouts = Map<GestureIntent, GestureLayout>.from(
        layouts[profileKey] ?? {},
      );

      for (final intent in intents) {
        if (defaultProfile.containsKey(intent)) {
          profileLayouts[intent] = defaultProfile[intent]!;
        }
      }

      layouts[profileKey] = profileLayouts;
    }

    set(state.copyWith(gestureLayoutProfiles: layouts));
    await _persist(state);
  }

  Future<void> updateControlsTitleConfig(TitleOverlayConfig config) async {
    set(state.copyWith(controlsTitleConfig: config));
    await _persist(state);
  }

  Future<void> updateMinimalTitleConfig(TitleOverlayConfig config) async {
    set(state.copyWith(minimalTitleConfig: config));
    await _persist(state);
  }

  Future<void> toggleUseClassicTitleBar() async {
    set(state.copyWith(useClassicTitleBar: !state.useClassicTitleBar));
    await _persist(state);
  }

  Future<void> toggleUseLegacyControlBar() async {
    set(state.copyWith(useLegacyControlBar: !state.useLegacyControlBar));
    await _persist(state);
  }

  Future<void> updateUseScenarioDrivenPlayback(bool value) async {
    set(state.copyWith(useScenarioDrivenPlayback: value));
    await _persist(state);
  }

  Future<void> toggleUseScenarioDrivenPlayback() async {
    set(state.copyWith(
        useScenarioDrivenPlayback: !state.useScenarioDrivenPlayback));
    await _persist(state);
  }

  Future<void> toggleUseLegacyStoragePersistence() async {
    EffectsRegistry.ensureRegistered();
    final newValue = !state.useLegacyStoragePersistence;
    set(state.copyWith(useLegacyStoragePersistence: newValue));
    await _persist(state);

    // Same effect the metadata path runs via mutatorKey — one implementation,
    // two entry points, identical behavior.
    await EffectsRegistry.run(EffectsRegistry.legacyStorageBackend, state);
  }

  Future<void> updateDefaultPopupDirection(PopupDirection direction) async {
    set(state.copyWith(defaultPopupDirection: direction));
    await _persist(state);
  }

  Future<void> updateBreadcrumbStartPortrait(BreadcrumbStartSide side) async {
    set(state.copyWith(breadcrumbStartPortrait: side));
    await _persist(state);
  }

  Future<void> updateBreadcrumbStartLandscape(BreadcrumbStartSide side) async {
    set(state.copyWith(breadcrumbStartLandscape: side));
    await _persist(state);
  }

  // =========================================================================
  // Persistence funnel (SettingsEngineHost implementation)
  //
  // Every mutation below funnels its persistence through [_persist], which
  // resolves the write matrix (PersistPolicy) from the flags ON THE SNAPSHOT
  // BEING WRITTEN. This single tail is what guarantees: legacy-mode writes
  // stay byte-for-byte legacy; metadata mode dual-writes per the sync gate;
  // and dialog-driven typed mutations land in the DB mirror exactly like
  // metadata-row mutations do.
  // =========================================================================

  /// The funnel tail. [next] must already be `set` — callers pass the same
  /// snapshot they applied so matrix flags are evaluated on it.
  Future<void> _persist(AppState next) async {
    final t = PersistPolicy.targets(next);
    if (t.writeBlob) await save(next);
    if (t.writeRows) await _persistChangedRows(next);
  }

  /// Rows side of [_persist]: upsert only the fields that changed since the
  /// last persisted snapshot.
  ///
  /// Falls back to a full snapshot replace when the baseline is unknown (fresh
  /// boot / after a fallback-to-blob load) so the mirror can never drift. The
  /// baseline is refreshed on every write, on load, and on gate transitions.
  Future<void> _persistChangedRows(AppState next) async {
    if (!MetaSettingsModule.ready) return;
    final encoded = StateBridge.encodeRows(next);
    final last = _lastPersistedRows;
    if (last == null) {
      await MetaSettingsModule.persistState(next);
      _lastPersistedRows = encoded;
      return;
    }
    final changed = <String, String>{};
    encoded.forEach((key, value) {
      if (last[key] != value) changed[key] = value;
    });
    _lastPersistedRows = encoded;
    if (changed.isEmpty) return;
    await MetaSettingsModule.persistChangedRows(changed);
  }

  @override
  AppState get currentState => state;

  @override
  Future<void> persistSnapshot(AppState next) => _persist(next);

  /// Master gate of the metadata settings subsystem.
  ///
  /// Transition semantics are intentionally NOT the generic write path:
  ///  - the blob is written UNCONDITIONALLY both ways (boot-time gate
  ///    discovery reads only the blob — a transition honoring the sync gate
  ///    could vanish across a restart);
  ///  - enabling seeds/refreshes the mirror AFTER the flag flips, so the
  ///    stored snapshot carries useMetadataSettings=true (an earlier version
  ///    snapshotted before flipping and a reboot silently reverted the gate);
  ///  - enabling then re-hydrates the auxiliary-only domains onto the live
  ///    state, so a legacy→meta switch restores them immediately (no restart);
  ///  - disabling reverse-exports first (blob now mirrors what rows held,
  ///    even after a sync-OFF period) and then clears ONLY the `app.*` rows.
  ///    Auxiliary-only domains are NOT part of the blob and are the DB's sole
  ///    responsibility, so they MUST survive the legacy period intact — the
  ///    old whole-table wipe was neither lossless nor recoverable.
  @override
  Future<void> setMetadataGate(bool next) async {
    if (state.useMetadataSettings == next) return;
    EffectsRegistry.ensureRegistered();
    // Enabling makes the use mode the placement authority, so fold the paired
    // legacy slider type onto it NOW: a blob written under the gate-OFF path
    // (where the two were picked independently) must not keep steering
    // resolveControlPanelAnchor on the meta side. Runs before the snapshot
    // write, so the very first seeded row already carries the folded value.
    final nextState = next
        ? state.copyWith(
            useMetadataSettings: next,
            phoneLandscapeSliderType: sliderTypeForUseMode(
                state.phoneLandscapeUseMode),
          )
        : state.copyWith(useMetadataSettings: next);
    set(nextState);

    try {
      await save(nextState); // forced: discovery + rollback anchor
      if (next) {
        await MetaSettingsModule.repo.replaceAllRawEntries(
          StateBridge.encodeRows(nextState)
              .entries
              .map((e) => SettingValuesTableCompanion.insert(
                    key: e.key,
                    value: e.value,
                  ))
              .toList(),
        );
        // Hot re-hydration: the gate switched ON just now, so the AUX domains
        // that were skipped while OFF snap back onto the live state. The rows
        // were never deleted, so gate-ON is itself the recovery point — no
        // restart required. Best-effort: applyAuxDomains degrades to `state`
        // on any error and never blocks the transition.
        final withAux = await applyAuxDomains(state);
        if (!identical(withAux, state)) set(withAux);
        // The full snapshot just landed; adopt it as the diff baseline.
        _lastPersistedRows = StateBridge.encodeRows(state);
      } else {
        await MetaSettingsModule.repo.clearAppValues();
        // No app.* rows exist while the gate is OFF; force a full reseed on
        // the next gate-ON / first mutation instead of diffing against stale.
        _lastPersistedRows = null;
      }
    } catch (e) {
      areaKeyLog.e('setMetadataGate($next) mirror sync failed: $e');
    }
  }

  Future<void> toggleUseMetadataSettings() =>
      setMetadataGate(!state.useMetadataSettings);

  /// Dual-write policy switch (only meaningful while the master gate is ON).
  Future<void> toggleSyncLegacyBlob() async {
    set(state.copyWith(syncLegacyBlob: !state.syncLegacyBlob));
    await _persist(state);
  }

  /// Generic metadata-settings mutation path (apply ONLY).
  ///
  /// Applies (field, jsonValue) through AppState.fromJson so type safety is
  /// enforced at ONE boundary; returns the applied state (null = rejected).
  /// PERSISTENCE CONTRACT: callers persist via [persistSnapshot] — the engine
  /// does this automatically; direct callers must not forget.
  @override
  Future<AppState?> applyJsonField(String field, Object? jsonValue) async {
    try {
      if (field == 'useScenarioDrivenPlayback' || field == 'autoPlay') {
        throw ArgumentError('Field "$field" is not metadata-writable');
      }
      final payload = state.toJson();
      payload[field] = jsonValue;
      // String round-trip normalizes nested freezed values (some generated
      // toJson impls emit instances where fromJson expects maps — the same
      // contract the legacy blob and importer already rely on).
      final next = AppState.fromJson(
        json.decode(json.encode(payload)) as Map<String, dynamic>,
      );
      // The round-trip drops every JsonKey-excluded (AUX-backed) field, so
      // re-hydrate those domains from the DB before publishing: without this
      // an unrelated settings edit resets the queue toolbar, the form
      // geometry and the dock theme to defaults until the next restart.
      final hydrated = await applyAuxDomains(next);
      set(hydrated);
      return hydrated;
    } catch (e) {
      areaKeyLog.e('applyJsonField($field): $e');
      return null;
    }
  }

  @override
  Future<AppState?> load() async {
    areaKeyLog.i('Loading AppState');
    try {
      final storage = getKvStore();

      String? appStateJson = await storage.read(key: 'app_state');

      // Metadata-settings gate routing: when enabled, setting_values is the
      // source of truth; the legacy blob only seeds it (first boot, once)
      // and keeps being double-written as the rollback mirror.
      if (StateBridge.gateEnabledInBlob(appStateJson) &&
          MetaSettingsModule.ready) {
        try {
          if (appStateJson != null) {
            await MetaSettingsModule.importLegacyBlobIfNeeded(
              json.decode(appStateJson) as Map<String, dynamic>,
            );
          }
          final rows = await MetaSettingsModule.repo.loadRawValues();
          final fromDb = StateBridge.materialize(rows);
          if (fromDb != null) {
            final normalized = _normalizeLoaded(fromDb);
            final withAux = await applyAuxDomains(normalized);
            // Adopt the loaded state as the diff baseline: rows already in the
            // DB are authoritative, so only genuinely new changes get written.
            _lastPersistedRows = StateBridge.encodeRows(withAux);
            // Portable fresh install: seed autoResize true when no explicit row/blob.
            if (isDesktop &&
                AppPaths.isPortable &&
                !rows.containsKey('app.autoResize') &&
                !withAux.autoResize) {
              final seeded = withAux.copyWith(autoResize: true);
              // Seed via the StateBridge JSON dialect ('true', not ValueCodec
              // '1') so the row survives the next materialize(); a ValueCodec
              // bool here is type-incompatible and gets dropped on reboot.
              final autoResizeRow = StateBridge.encodeField(true);
              try {
                if (autoResizeRow != null) {
                  await MetaSettingsModule.repo
                      .saveRawValue('app.autoResize', autoResizeRow);
                }
                await save(seeded);
              } catch (_) {}
              _lastPersistedRows = StateBridge.encodeRows(seeded);
              return seeded;
            }
            return withAux;
          }
          areaKeyLog.w('Meta settings rows unusable, falling back to blob');
        } catch (e) {
          areaKeyLog.e('Meta settings load failed, falling back to blob: $e');
        }
      }

      if (appStateJson != null) {
        var appState = AppState.fromJson(json.decode(appStateJson)).copyWith(
          autoPlay: false, // your existing logic
        );
        // Legacy/fallback path → the rows mirror is not our baseline; force a
        // full reseed on the next metadata mutation.
        _lastPersistedRows = null;
        return applyAuxDomains(_normalizeLoaded(appState));
      }
      // No blob at all — fresh install. Portable Windows defaults autoResize ON.
      if (isDesktop && AppPaths.isPortable) {
        final seeded = await applyAuxDomains(
            _normalizeLoaded(const AppState(autoResize: true)));
        try {
          await save(seeded);
        } catch (_) {}
        _lastPersistedRows = null;
        return seeded;
      }
    } catch (e) {
      // Never swallow: a failed load must keep loadOk false so the
      // PersistentStore durability gate blocks writes instead of
      // overwriting the user's settings with defaults.
      areaKeyLog.e('Error loading AppState: $e');
      rethrow;
    }
    return null;
  }

  /// Rehydrates the dial-ring styling overrides onto [base].
  ///
  /// Metadata-mode-only (gate ON + module ready); anything else — including
  /// corrupt rows or unknown enum names — degrades to [base] untouched.
  /// Public because widget tests cannot drive load()'s blob-gate peek
  /// (no secure-storage plugin) and exercise this step directly.
  Future<AppState> applyDialRingRows(AppState base,
      {Map<String, String>? prefetched}) async {
    if (!base.useMetadataSettings || !MetaSettingsModule.ready) return base;
    final Map<String, String> rows =
        prefetched ?? await MetaSettingsModule.loadDialRingRows();
    if (rows.isEmpty) return base;
    return _decodeDialRing(rows, base);
  }

  /// Rehydrates the browse-media-scope override onto [base].
  ///
  /// Metadata-mode-only; corrupt/unknown rows degrade to [base] untouched.
  /// Public for the same reason as [applyDialRingRows]: widget tests cannot
  /// drive load()'s blob-gate peek.
  Future<AppState> applyBrowseRows(AppState base,
      {Map<String, String>? prefetched}) async {
    if (!base.useMetadataSettings || !MetaSettingsModule.ready) return base;
    final Map<String, String> rows =
        prefetched ?? await MetaSettingsModule.loadBrowseRows();
    final String? raw = rows['mediaScope'];
    if (raw == null) return base;
    for (final s in BrowseMediaScope.values) {
      if (s.name == raw) return base.copyWith(browseMediaScope: s);
    }
    return base;
  }

  /// Rehydrates the resume-on-startup override onto [base].
  ///
  /// Metadata-mode-only; malformed rows degrade to [base] untouched (same
  /// contract as [applyBrowseRows]).
  Future<AppState> applyPlaybackRows(AppState base,
      {Map<String, String>? prefetched}) async {
    if (!base.useMetadataSettings || !MetaSettingsModule.ready) return base;
    final Map<String, String> rows =
        prefetched ?? await MetaSettingsModule.loadPlaybackRows();
    final String? raw = rows['resumeOnStartup'];
    final String? dropRaw = rows['dropAppendPercent'];
    final String? cacheRaw = rows['videoCachePreset'];
    final String? stepModeRaw = rows['stepSeekMode'];
    return base.copyWith(
      resumeOnStartup: raw == null
          ? base.resumeOnStartup
          : ValueCodec.decodeBool(raw, fallback: base.resumeOnStartup),
      dropAppendZonePercent: dropRaw == null
          ? base.dropAppendZonePercent
          : ValueCodec.decodeDouble(dropRaw,
                  fallback: base.dropAppendZonePercent)
              .clamp(10.0, 90.0)
              .toDouble(),
      // Malformed / unknown names degrade to [base] (same contract as the
      // fields above).
      videoCachePreset: cacheRaw == null
          ? base.videoCachePreset
          : VideoCachePreset.values.firstWhere(
              (v) => v.name == cacheRaw,
              orElse: () => base.videoCachePreset,
            ),
      stepSeekMode: stepModeRaw == null
          ? base.stepSeekMode
          : StepSeekMode.values.firstWhere(
              (v) => v.name == stepModeRaw,
              orElse: () => base.stepSeekMode,
            ),
    );
  }

  Future<AppState> applyVirtualMediaRows(AppState base,
      {Map<String, String>? prefetched}) async {
    // Gate ON only. The `useLegacyStoragePersistence` toggle no longer blocks
    // rehydration: legacy storage mode does not USE virtual media, but
    // switching modes must never discard the VM preferences a user chose in
    // the meta era — the rows stay in the DB, so they are always re-applied.
    if (!base.useMetadataSettings || !MetaSettingsModule.ready) return base;
    final rows = prefetched ?? await MetaSettingsModule.loadVirtualMediaRows();
    if (rows.isEmpty) return base;
    // One-version migration: legacy `vm*` rows (pre Def-alignment) resolve
    // when the canonical short field is absent, then migrate forward so the
    // legacy row is never read again. Awaited: startup must observe the
    // migrated row (and tests assert it) before this returns.
    final pendingMigration = <Future<void>>[];
    String? readVm(String canonical) {
      final legacy = kVmCanonicalToLegacyField[canonical]!;
      final raw = resolveVmRowValue(rows, canonical, legacy);
      if (raw != null && !rows.containsKey(canonical)) {
        pendingMigration
            .add(MetaSettingsModule.saveVirtualMediaRow(canonical, raw));
      }
      return raw;
    }

    var next = base;
    final stratRaw = readVm('crossDragStrategy');
    if (stratRaw != null) {
      for (final v in VmCrossSegmentDragStrategy.values) {
        if (v.name == stratRaw) {
          next = next.copyWith(vmCrossSegmentDragStrategy: v);
          break;
        }
      }
    }
    final dualSyncRaw = readVm('dualTimeSync');
    if (dualSyncRaw != null) {
      for (final v in VmDualTimeSyncMode.values) {
        if (v.name == dualSyncRaw) {
          next = next.copyWith(vmDualTimeSync: v);
          break;
        }
      }
    }
    final hideRaw = readVm('hideChunkWhenSingleSegment');
    if (hideRaw != null) {
      final b = ValueCodec.decodeBool(hideRaw,
          fallback: next.vmHideChunkWhenSingleSegment);
      next = next.copyWith(vmHideChunkWhenSingleSegment: b);
    }
    final tickRaw = readVm('markTickColor');
    if (tickRaw != null) {
      // Corrupt rows degrade to opaque white (never break the slider).
      next = next.copyWith(vmMarkTickColor: sanitizeVmTickColorArgb(tickRaw));
    }
    final extentRaw = readVm('markTickExtent');
    if (extentRaw != null) {
      next = next.copyWith(vmMarkTickExtent: sanitizeVmTickExtentPx(extentRaw));
    }
    if (pendingMigration.isNotEmpty) {
      await Future.wait(pendingMigration);
    }
    return next;
  }

  // ── Screenshot save dirs (metadata era) ─────────────────────────────────
  // AUX `screenshot.` rows — JsonKey-excluded, per-platform. Gate OFF keeps
  // edits memory-only; capture resolves through the platform defaults.

  Future<void> _saveScreenshotRow(
      String field, Object? value, SettingValueType type) async {
    if (!state.useMetadataSettings || !MetaSettingsModule.ready) return;
    final String? encoded = ValueCodec.encode(type, value);
    if (encoded == null) return;
    await MetaSettingsModule.saveScreenshotRow(field, encoded);
  }

  Future<void> updateScreenshotMobileDir(String v) async {
    set(state.copyWith(screenshotMobileDir: v));
    await _saveScreenshotRow('mobileDir', v, SettingValueType.string);
  }

  Future<void> updateScreenshotDesktopDir(String v) async {
    set(state.copyWith(screenshotDesktopDir: v));
    await _saveScreenshotRow('desktopDir', v, SettingValueType.string);
  }

  /// Decodes a stored `"x,y"` fraction pair, tolerating the JSON-quoted form
  /// older builds may have written. Null on anything malformed, so the caller
  /// keeps the default placement instead of parking a widget at NaN.
  static Offset? _decodeFraction(String? raw) {
    if (raw == null) return null;
    try {
      final String decoded = ValueCodec.decodeString(raw) ?? raw;
      final List<String> parts = decoded.split(',');
      if (parts.length != 2) return null;
      final double? x = double.tryParse(parts[0].trim());
      final double? y = double.tryParse(parts[1].trim());
      if (x == null || y == null || x.isNaN || y.isNaN) return null;
      return Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
    } catch (_) {
      return null;
    }
  }

  /// Commits the frame-tools float panel position ONCE, at the end of a drag.
  ///
  /// Fractions are clamped to [0,1] so a stored value can never park the panel
  /// outside the host; the drag itself stays memory-only (see the panel's
  /// `onPanUpdate`), exactly like the control-group floating button.
  Future<void> updateFrameToolsPanelFraction(Offset fraction) async {
    final Offset clamped = Offset(
      fraction.dx.clamp(0.0, 1.0).toDouble(),
      fraction.dy.clamp(0.0, 1.0).toDouble(),
    );
    if (state.frameToolsPanelFraction == clamped) return;
    set(state.copyWith(frameToolsPanelFraction: clamped));
    // "x,y" string, the same shape sidePanelDialogOffset already round-trips.
    await _saveScreenshotRow(
        'frameToolsOffset', '${clamped.dx},${clamped.dy}',
        SettingValueType.string);
  }

  Future<AppState> applyScreenshotRows(AppState base,
      {Map<String, String>? prefetched}) async {
    if (!base.useMetadataSettings || !MetaSettingsModule.ready) return base;
    final rows = prefetched ?? await MetaSettingsModule.loadScreenshotRows();
    if (rows.isEmpty) return base;
    var next = base;
    final mobileRaw = rows['mobileDir'];
    if (mobileRaw != null) {
      next = next.copyWith(
          screenshotMobileDir:
              ValueCodec.decodeString(mobileRaw) ?? next.screenshotMobileDir);
    }
    final desktopRaw = rows['desktopDir'];
    if (desktopRaw != null) {
      next = next.copyWith(
          screenshotDesktopDir:
              ValueCodec.decodeString(desktopRaw) ?? next.screenshotDesktopDir);
    }
    final offsetRaw = rows['frameToolsOffset'];
    if (offsetRaw != null) {
      try {
        final String decoded =
            ValueCodec.decodeString(offsetRaw) ?? offsetRaw;
        final List<String> parts = decoded.split(',');
        if (parts.length == 2) {
          final double? x = double.tryParse(parts[0]);
          final double? y = double.tryParse(parts[1]);
          if (x != null && y != null) {
            next = next.copyWith(
              frameToolsPanelFraction:
                  Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0)),
            );
          }
        }
      } catch (_) {
        // Malformed row: keep the default centred placement.
      }
    }
    return next;
  }

  Future<void> _saveSpeedRow(
      String field, Object? value, SettingValueType type) async {
    // Same shape as every other AUX _saveXRow helper: gate OFF (or DB not yet
    // ready) drops the write; the live state still updates.
    if (!state.useMetadataSettings || !MetaSettingsModule.ready) return;
    final String? encoded = ValueCodec.encode(type, value);
    if (encoded == null) return;
    await MetaSettingsModule.saveSpeedRow(field, encoded);
  }

  Future<void> updateSpeedGestureMode(SpeedGestureMode mode) async {
    set(state.copyWith(speedGestureMode: mode));
    await _saveSpeedRow('gestureMode', mode.name, SettingValueType.enumeration);
  }

  Future<void> updateSpeedRatePickerMode(SpeedRatePickerMode mode) async {
    set(state.copyWith(speedRatePickerMode: mode));
    await _saveSpeedRow('rateMode', mode.name, SettingValueType.enumeration);
  }

  /// Commits the speed picker card's position ONCE, at the end of a drag.
  ///
  /// Fractions are clamped to [0,1] so a stored value can never park the card
  /// outside its travel; drag frames stay memory-only (see
  /// `DraggableDialogShell`), exactly like the control-group floating button.
  Future<void> updateSpeedRateDialogOffset(Offset fraction) async {
    final Offset clamped = Offset(
      fraction.dx.clamp(0.0, 1.0).toDouble(),
      fraction.dy.clamp(0.0, 1.0).toDouble(),
    );
    if (state.speedRateDialogOffset == clamped) return;
    set(state.copyWith(speedRateDialogOffset: clamped));
    // "x,y" string, the same shape sidePanelDialogOffset already round-trips.
    await _saveSpeedRow(
        'dialogOffset', '${clamped.dx},${clamped.dy}', SettingValueType.string);
  }

  Future<AppState> applySpeedRows(AppState base,
      {Map<String, String>? prefetched}) async {
    if (!base.useMetadataSettings || !MetaSettingsModule.ready) return base;
    final Map<String, String> rows =
        prefetched ?? await MetaSettingsModule.loadSpeedRows();
    if (rows.isEmpty) return base;

    // ValueCodec stores enumeration names verbatim; tolerate the JSON-quoted
    // form older builds may have written.
    String? name(String field) {
      var raw = rows[field]?.trim();
      if (raw == null) return null;
      if (raw.startsWith('"') && raw.endsWith('"') && raw.length >= 2) {
        try {
          final decoded = json.decode(raw);
          if (decoded is String) raw = decoded;
        } catch (_) {}
      }
      return raw;
    }

    T? match<T extends Enum>(String? raw, List<T> values) {
      if (raw == null) return null;
      for (final v in values) {
        if (v.name == raw) return v;
      }
      return null;
    }

    var next = base;
    final String? gestureRaw = name('gestureMode');
    if (gestureRaw != null) {
      final mode = match(gestureRaw, SpeedGestureMode.values);
      if (mode != null) {
        next = next.copyWith(speedGestureMode: mode);
      } else {
        areaKeyLog.w(
            'applySpeedRows: unknown gestureMode "$gestureRaw", keep ${next.speedGestureMode}');
      }
    }
    final String? rateRaw = name('rateMode');
    if (rateRaw != null) {
      final mode = match(rateRaw, SpeedRatePickerMode.values);
      if (mode != null) {
        next = next.copyWith(speedRatePickerMode: mode);
      } else {
        areaKeyLog.w(
            'applySpeedRows: unknown rateMode "$rateRaw", keep ${next.speedRatePickerMode}');
      }
    }
    final String? offsetRaw = rows['dialogOffset'];
    if (offsetRaw != null) {
      try {
        final String decoded = ValueCodec.decodeString(offsetRaw) ?? offsetRaw;
        final List<String> parts = decoded.split(',');
        if (parts.length == 2) {
          final double? x = double.tryParse(parts[0]);
          final double? y = double.tryParse(parts[1]);
          if (x != null && y != null) {
            next = next.copyWith(
              speedRateDialogOffset:
                  Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0)),
            );
          }
        }
      } catch (_) {
        // Malformed row: keep the centred default.
      }
    }
    return next;
  }

  /// Rehydrates EVERY auxiliary (`<domain>.`) domain onto [base].
  ///
  /// Historically named after its first domain (dial-ring) even though it
  /// cascaded all of them. One `loadAllRows()` read is shared across the
  /// cascade; each domain slices `setting_values` locally via [sliceAux]
  /// instead of issuing its own full-table scan.
  Future<AppState> applyAuxDomains(AppState base) async {
    if (!base.useMetadataSettings || !MetaSettingsModule.ready) return base;
    try {
      final all = await MetaSettingsModule.loadAllRows() ?? const {};
      Map<String, String> slice(String prefix) =>
          MetaSettingsModule.sliceAux(all, prefix);
      final withDial = await applyDialRingRows(base,
          prefetched: slice(MetaSettingsModule.kDialRingRowPrefix));
      final withBrowse = await applyBrowseRows(withDial,
          prefetched: slice(MetaSettingsModule.kBrowseRowPrefix));
      final withPlayback = await applyPlaybackRows(withBrowse,
          prefetched: slice(MetaSettingsModule.kPlaybackRowPrefix));
      final withOsd = await applyOsdRows(withPlayback,
          prefetched: slice(MetaSettingsModule.kOsdRowPrefix));
      final withWindow = await applyWindowRows(withOsd,
          prefetched: slice(MetaSettingsModule.kWindowRowPrefix));
      final withForm = await applyFormRows(withWindow,
          prefetched: slice(MetaSettingsModule.kFormRowPrefix));
      final withVideo = await applyVideoRows(withForm,
          prefetched: slice(MetaSettingsModule.kVideoRowPrefix));
      final withSlider = await applySliderRows(withVideo,
          prefetched: slice(MetaSettingsModule.kSliderRowPrefix));
      final withSpeed = await applySpeedRows(withSlider,
          prefetched: slice(MetaSettingsModule.kSpeedRowPrefix));
      final withKeybind = await applyKeybindRows(withSpeed,
          prefetched: slice(MetaSettingsModule.kKeybindRowPrefix));
      final withVirtualMedia = await applyVirtualMediaRows(withKeybind,
          prefetched: slice(MetaSettingsModule.kVirtualMediaRowPrefix));
      return await applyScreenshotRows(withVirtualMedia,
          prefetched: slice(MetaSettingsModule.kScreenshotRowPrefix));
    } catch (e) {
      areaKeyLog.w('aux overrides unreadable: $e');
      return base;
    }
  }

  // ── Desktop window / playlist dock ────────────────────────────────────
  // AUX `window.` rows — JsonKey-excluded, desktop-only.

  Future<void> _saveWindowRow(
      String field, Object? value, SettingValueType type) async {
    if (!state.useMetadataSettings || !MetaSettingsModule.ready) return;
    final String? encoded = ValueCodec.encode(type, value);
    if (encoded == null) return;
    await MetaSettingsModule.saveWindowRow(field, encoded);
  }

  // ── Shared keyboard-form geometry ──────────────────────────────────────
  // AUX `form.` rows — JsonKey-excluded, no user-facing setting row.

  Future<void> _saveFormRow(String field, String encoded) async {
    if (!state.useMetadataSettings || !MetaSettingsModule.ready) return;
    await MetaSettingsModule.saveFormRow(field, encoded);
  }

  /// Commits the keyboard form's remembered box ONCE, at the end of a gesture.
  ///
  /// Fractions are clamped on the way in so a stored value can never park the
  /// form outside its travel, and drag/resize frames stay memory-only (see
  /// `DraggableDialogShell`) — one Drift write per gesture, never per frame.
  Future<void> updateKeyboardFormGeometry(KeyboardFormGeometry geometry) async {
    final KeyboardFormGeometry clamped = KeyboardFormGeometry.clamped(
      offset: geometry.offset,
      widthFraction: geometry.widthFraction,
    );
    if (state.keyboardFormGeometry == clamped) return;
    set(state.copyWith(keyboardFormGeometry: clamped));
    // "dx,dy[,width]" — the same bare shape speed.dialogOffset round-trips.
    await _saveFormRow('geometry', clamped.encode());
  }

  Future<AppState> applyFormRows(AppState base,
      {Map<String, String>? prefetched}) async {
    if (!base.useMetadataSettings || !MetaSettingsModule.ready) return base;
    final Map<String, String> rows =
        prefetched ?? await MetaSettingsModule.loadFormRows();
    if (rows.isEmpty) return base;
    // parse() degrades a corrupt row to the centred default rather than
    // throwing: a bad geometry must not strand the form off-screen.
    return base.copyWith(
      keyboardFormGeometry: KeyboardFormGeometry.parse(rows['geometry']),
    );
  }

  Future<void> updatePlaylistPanelMode(PlaylistPanelMode mode) async {
    set(state.copyWith(playlistPanelMode: mode));
    await _saveWindowRow(
        'playlistPanelMode', mode.name, SettingValueType.enumeration);
  }

  Future<void> togglePlaylistPanelMode() async {
    final next = state.playlistPanelMode == PlaylistPanelMode.popup
        ? PlaylistPanelMode.dockedRight
        : PlaylistPanelMode.popup;
    await updatePlaylistPanelMode(next);
    // Auto-show the queue when docking so the user sees the effect immediately.
    if (next == PlaylistPanelMode.dockedRight && !state.playlistPanelVisible) {
      await updatePlaylistPanelVisible(true);
    }
  }

  Future<void> updatePlaylistPanelVisible(bool visible) async {
    set(state.copyWith(playlistPanelVisible: visible));
    await _saveWindowRow(
        'playlistPanelVisible', visible, SettingValueType.bool);
  }

  Future<void> togglePlaylistPanelVisible() async {
    await updatePlaylistPanelVisible(!state.playlistPanelVisible);
  }

  Future<void> updatePlaylistPanelWidth(double width) async {
    // Keep clamp in sync with resolve_playlist_dock.dart (240.. min(600, maxWidth*0.5)).
    // Here we only enforce the absolute bounds; Home clamps the upper bound by maxWidth.
    final double clamped = width.clamp(240.0, 600.0);
    set(state.copyWith(playlistPanelWidth: clamped));
    await _saveWindowRow(
        'playlistPanelWidth', clamped, SettingValueType.double);
  }

  Future<void> updateSideFullscreenBehavior(SideFullscreenBehavior v) async {
    set(state.copyWith(sideFullscreenBehavior: v));
    await _saveWindowRow(
        'sideFullscreenBehavior', v.name, SettingValueType.enumeration);
  }

  /// Right-edge activation strip width (percentage of the playback area) for
  /// the picture-fullscreen dock peek. Hard-clamped through
  /// [clampFullscreenDockEdgePct] so a bad stored value can never produce an
  /// unusable hot-zone.
  Future<void> updateFullscreenDockEdgeRevealPct(double pct) async {
    final double clamped = clampFullscreenDockEdgePct(pct);
    set(state.copyWith(fullscreenDockEdgeRevealPct: clamped));
    await _saveWindowRow(
        'fullscreenDockEdgeRevealPct', clamped, SettingValueType.double);
  }

  /// Isolation zone of the one-handed side-type panel for the fullscreen queue
  /// summon strip, as a percentage of the playback-area height (added to the
  /// panel height). Hard-clamped through [clampSidePanelIsolationPct].
  Future<void> updateSidePanelIsolationPct(double pct) async {
    final double clamped = clampSidePanelIsolationPct(pct);
    set(state.copyWith(sidePanelIsolationPct: clamped));
    await _saveWindowRow(
        'sidePanelIsolationPct', clamped, SettingValueType.double);
  }

  /// Isolation zone of the normal long-strip control bar for the fullscreen
  /// queue summon strip, as a percentage of the playback-area height (added to
  /// the bar's measured height). Hard-clamped through
  /// [clampLinearBarIsolationPct].
  Future<void> updateLinearBarIsolationPct(double pct) async {
    final double clamped = clampLinearBarIsolationPct(pct);
    set(state.copyWith(linearBarIsolationPct: clamped));
    await _saveWindowRow(
        'linearBarIsolationPct', clamped, SettingValueType.double);
  }

  Future<void> updatePlaylistPopupTheme(PlaylistPopupTheme v) async {
    set(state.copyWith(playlistPopupTheme: v));
    await _saveWindowRow(
        'playlistPopupTheme', v.name, SettingValueType.enumeration);
  }

  Future<void> updatePlaylistDockTheme(PlaylistDockTheme v) async {
    set(state.copyWith(playlistDockTheme: v));
    await _saveWindowRow(
        'playlistDockTheme', v.name, SettingValueType.enumeration);
  }

  /// Scenario play-queue toolbar layout for ONE screen shape. Read by the queue
  /// page for every mount (floating popup, side dock, storages-db host), so
  /// flipping it restyles the mounted queue without a reopen.
  ///
  /// Per profile on purpose: a sideways phone has room for a different toolbar
  /// than the same phone upright, and the desktop dock is a third shape again.
  Future<void> updateScenarioQueueLayout(
      ScenarioQueueProfile profile, ScenarioQueueLayout layout) async {
    set(state.withScenarioQueueLayout(profile, layout));
    await _saveWindowRow(
        profile.layoutRow, layout.name, SettingValueType.enumeration);
  }

  /// The queue's own one-button layout switch. Cycles v1 → v2 → v3 → v1 within
  /// [profile] alone, so using the button on a phone never edits what the
  /// desktop will show.
  Future<void> toggleScenarioQueueLayout(ScenarioQueueProfile profile) async {
    await updateScenarioQueueLayout(
        profile, nextScenarioQueueLayout(state.scenarioQueueLayoutFor(profile)));
  }

  /// Commits the V3 floating bar's position ONCE, at the end of a drag.
  ///
  /// Fractions are clamped to [0,1] so a stored value can never park the bar
  /// outside the list area; the drag itself stays memory-only (see
  /// `FloatingGridBar`'s `onPanUpdate`), exactly like the frame-tools float
  /// panel and the control-group floating button.
  Future<void> updateScenarioQueueBarOffset(
      ScenarioQueueProfile profile, Offset fraction) async {
    final Offset clamped = Offset(
      fraction.dx.clamp(0.0, 1.0).toDouble(),
      fraction.dy.clamp(0.0, 1.0).toDouble(),
    );
    if (state.scenarioQueueBarOffsetFor(profile) == clamped) return;
    set(state.withScenarioQueueBarOffset(profile, clamped));
    // "x,y" string, the same shape sidePanelDialogOffset already round-trips.
    await _saveWindowRow(
        profile.barOffsetRow, '${clamped.dx},${clamped.dy}',
        SettingValueType.string);
  }

  /// Breadcrumb visibility of the scenario play queue. Deliberately has no
  /// settings row: the queue's V2 overflow checkbox is the single control, and
  /// both layouts read this one value.
  Future<void> updateScenarioQueueShowBreadcrumb(bool visible) async {
    set(state.copyWith(scenarioQueueShowBreadcrumb: visible));
    await _saveWindowRow(
        'scenarioQueueShowBreadcrumb', visible, SettingValueType.bool);
  }

  /// Desktop window-fit mode (窗口适应模式). Runtime toggle: the control-bar
  /// button and Ctrl+R (gate ON) flip it; every video open/switch re-applies
  /// [WindowFitMode.fitVideo].
  Future<void> updateWindowFitMode(WindowFitMode mode) async {
    set(state.copyWith(windowFitMode: mode));
    await _saveWindowRow('fitMode', mode.name, SettingValueType.enumeration);
  }

  Future<void> toggleWindowFitMode() async {
    await updateWindowFitMode(nextWindowFitMode(state.windowFitMode));
  }

  /// Keep window inside screen when switching videos (desktop, meta-driven).
  /// Persisted as `window.keepInBounds` AUX row — gate OFF degrades to no clamp.
  Future<void> updateKeepWindowInBounds(bool value) async {
    set(state.copyWith(keepWindowInBounds: value));
    await _saveWindowRow('keepInBounds', value, SettingValueType.bool);
  }

  Future<void> toggleKeepWindowInBounds() async {
    await updateKeepWindowInBounds(!state.keepWindowInBounds);
  }

  // ── Video display mode (metadata era) ──────────────────────────────────
  // AUX `video.` rows — JsonKey-excluded. Gate-OFF keeps the legacy `fit`
  // cycle; these setters are only reached from gate-ON UI.

  Future<void> _saveVideoRow(
      String field, Object? value, SettingValueType type) async {
    if (!state.useMetadataSettings || !MetaSettingsModule.ready) return;
    final String? encoded = ValueCodec.encode(type, value);
    if (encoded == null) return;
    await MetaSettingsModule.saveVideoRow(field, encoded);
  }

  Future<void> updateDesktopDisplayMode(DesktopVideoDisplayMode mode) async {
    set(state.copyWith(desktopDisplayMode: mode));
    await _saveVideoRow(
        'desktopDisplayMode', mode.name, SettingValueType.enumeration);
  }

  Future<void> updateMobileDisplayMode(MobileVideoDisplayMode mode) async {
    set(state.copyWith(mobileDisplayMode: mode));
    await _saveVideoRow(
        'mobileDisplayMode', mode.name, SettingValueType.enumeration);
  }

  /// Cycles the platform-appropriate display mode (gate-ON UI only). Windows
  /// and phone carry separate enums — see video_display_mode.dart.
  Future<void> cycleVideoDisplayMode() async {
    if (isMobilePlatform) {
      await updateMobileDisplayMode(
          nextMobileVideoDisplayMode(state.mobileDisplayMode));
    } else {
      await updateDesktopDisplayMode(
          nextDesktopVideoDisplayMode(state.desktopDisplayMode));
    }
  }

  /// Rehydrates the video display-mode rows onto [base].
  /// Metadata-mode-only; corrupt/unknown rows degrade to [base] untouched.
  Future<AppState> applyVideoRows(AppState base,
      {Map<String, String>? prefetched}) async {
    if (!base.useMetadataSettings || !MetaSettingsModule.ready) return base;
    final Map<String, String> rows =
        prefetched ?? await MetaSettingsModule.loadVideoRows();
    if (rows.isEmpty) return base;
    T? enm<T extends Enum>(String? raw, List<T> values) {
      if (raw == null) return null;
      for (final v in values) {
        if (v.name == raw) return v;
      }
      return null;
    }

    return base.copyWith(
      desktopDisplayMode:
          enm(rows['desktopDisplayMode'], DesktopVideoDisplayMode.values) ??
              base.desktopDisplayMode,
      mobileDisplayMode:
          enm(rows['mobileDisplayMode'], MobileVideoDisplayMode.values) ??
              base.mobileDisplayMode,
    );
  }

  // ── Sideway panel anchor (metadata era) ────────────────────────────────
  // AUX `slider.` rows — JsonKey-excluded. Gate-OFF derives the anchor from
  // phoneLandscapeUseMode (resolveSidePanelAlignment); these setters are
  // only reached from gate-ON UI.

  Future<void> _saveSliderRow(
      String field, Object? value, SettingValueType type) async {
    if (!state.useMetadataSettings || !MetaSettingsModule.ready) return;
    final String? encoded = ValueCodec.encode(type, value);
    if (encoded == null) return;
    await MetaSettingsModule.saveSliderRow(field, encoded);
  }

  /// Moves the desktop one-handed panel horizontally.
  ///
  /// The anchor decides the panel's POSITION; the paired use mode carries the
  /// HANDEDNESS the scrubber mirrors by, so both are written here — a centre
  /// anchor keeps the existing hand, and `normal` mode is never resurrected by
  /// a mere anchor change.
  ///
  /// Both must also REACH STORAGE here. The anchor is `@JsonKey`-excluded, so
  /// its only home is the `slider.posH` row; the mode is an ordinary persisted
  /// field (`app.phoneLandscapeUseMode` under the gate, the legacy blob
  /// otherwise) and needs the normal funnel. Writing just the anchor row left
  /// the hand behind, so a hard restart restored the position while silently
  /// reverting the ring mirroring — `updatePhoneLandscapeUseMode` is the
  /// reference for this two-call shape.
  Future<void> updatePhoneSidePositionH(PhoneSidePositionH pos) async {
    final bool sideway = state.phoneLandscapeUseMode.usesOneHandedControls;
    final PhoneLandscapeUseMode mode = sideway
        ? useModeForAnchorH(pos, state.phoneLandscapeUseMode)
        : state.phoneLandscapeUseMode;
    set(state.copyWith(
      phoneSidePositionH: pos,
      phoneLandscapeUseMode: mode,
      // The paired legacy placement follows the hand, so an anchor change can
      // never leave a stale corner behind.
      phoneLandscapeSliderType: sliderTypeForUseMode(mode),
    ));
    await _saveSliderRow('posH', pos.name, SettingValueType.enumeration);
    await _persist(state);
  }

  Future<void> updatePhoneSidePositionV(PhoneSidePositionV pos) async {
    set(state.copyWith(phoneSidePositionV: pos));
    await _saveSliderRow('posV', pos.name, SettingValueType.enumeration);
  }

  /// Moves the phone one-handed panel horizontally. Phones expose left/right
  /// only, so `center` collapses to `right` before it can reach the store.
  ///
  /// Persists the paired hand exactly like [updatePhoneSidePositionH]: the
  /// anchor row alone does not carry `phoneLandscapeUseMode`, so a restart
  /// would keep the side and drop the hand.
  Future<void> updateMobileSidePositionH(PhoneSidePositionH pos) async {
    final PhoneSidePositionH normalized =
        pos == PhoneSidePositionH.center ? PhoneSidePositionH.right : pos;
    final bool sideway = state.phoneLandscapeUseMode.usesOneHandedControls;
    final PhoneLandscapeUseMode mode = sideway
        ? useModeForAnchorH(normalized, state.phoneLandscapeUseMode)
        : state.phoneLandscapeUseMode;
    set(state.copyWith(
      mobileSidePositionH: normalized,
      phoneLandscapeUseMode: mode,
      phoneLandscapeSliderType: sliderTypeForUseMode(mode),
    ));
    await _saveSliderRow(
        'phonePosH', normalized.name, SettingValueType.enumeration);
    await _persist(state);
  }

  double _clampPanelPct(double v) => v.clamp(10.0, 100.0).toDouble();
  double _clampPanelPxW(double v) => v.clamp(260.0, 2000.0).toDouble();
  double _clampPanelPxH(double v) => v.clamp(320.0, 2000.0).toDouble();
  double _clampHandleInset(double v) => v.clamp(4.0, 2000.0).toDouble();
  double _clampHandleRadius(double v) => v.clamp(4.0, 16.0).toDouble();

  Future<void> updateSidewayPanelWidthPct(double pct,
      {bool persist = true}) async {
    final double clamped = _clampPanelPct(pct);
    set(state.copyWith(sidewayPanelWidthPct: clamped));
    if (persist) {
      await _saveSliderRow('widthPct', clamped, SettingValueType.double);
    }
  }

  Future<void> updateSidewayPanelHeightPct(double pct,
      {bool persist = true}) async {
    final double clamped = _clampPanelPct(pct);
    set(state.copyWith(sidewayPanelHeightPct: clamped));
    if (persist) {
      await _saveSliderRow('heightPct', clamped, SettingValueType.double);
    }
  }

  Future<void> updateSidewayPanelWidthPx(double px,
      {bool persist = true}) async {
    final double clamped = _clampPanelPxW(px);
    set(state.copyWith(sidewayPanelWidthPx: clamped));
    if (persist) {
      await _saveSliderRow('widthPx', clamped, SettingValueType.double);
    }
  }

  Future<void> updateSidewayPanelHeightPx(double px,
      {bool persist = true}) async {
    final double clamped = _clampPanelPxH(px);
    set(state.copyWith(sidewayPanelHeightPx: clamped));
    if (persist) {
      await _saveSliderRow('heightPx', clamped, SettingValueType.double);
    }
  }

  /// Commits the sideway panel geometry exactly once, at drag end.
  ///
  /// Live drag updates publish to memory only (`persist: false`); this writes
  /// the final row(s) so dragging the panel spawns ONE write instead of one
  /// per frame (Drift runs on the UI isolate). Phone uses screen %, desktop
  /// uses absolute px; the legacy `circleLandscapePercent` mirror is folded in
  /// on phone so the retired bar stays coherent.
  Future<void> persistSidewayPanelGeometry() async {
    if (isMobilePlatform) {
      await updateSidewayPanelWidthPct(state.sidewayPanelWidthPct);
      await updateSidewayPanelHeightPct(state.sidewayPanelHeightPct);
      await updateCircleLandscapePercent(state.circleLandscapePercent);
    } else {
      await updateSidewayPanelWidthPx(state.sidewayPanelWidthPx);
      await updateSidewayPanelHeightPx(state.sidewayPanelHeightPx);
    }
    await updateSidewayHandleInsetH(state.sidewayHandleInsetH);
    await updateSidewayHandleInsetV(state.sidewayHandleInsetV);
  }

  Future<void> updateSidewayHandleInsetH(double v,
      {bool persist = true}) async {
    final double clamped = _clampHandleInset(v);
    set(state.copyWith(sidewayHandleInsetH: clamped));
    if (persist) {
      await _saveSliderRow('handleInsetH', clamped, SettingValueType.double);
    }
  }

  Future<void> updateSidewayHandleInsetV(double v,
      {bool persist = true}) async {
    final double clamped = _clampHandleInset(v);
    set(state.copyWith(sidewayHandleInsetV: clamped));
    if (persist) {
      await _saveSliderRow('handleInsetV', clamped, SettingValueType.double);
    }
  }

  Future<void> updateSidewayHandleRadiusH(double v) async {
    final double clamped = _clampHandleRadius(v);
    set(state.copyWith(sidewayHandleRadiusH: clamped));
    await _saveSliderRow('handleRadiusH', clamped, SettingValueType.double);
  }

  Future<void> updateSidewayHandleRadiusV(double v) async {
    final double clamped = _clampHandleRadius(v);
    set(state.copyWith(sidewayHandleRadiusV: clamped));
    await _saveSliderRow('handleRadiusV', clamped, SettingValueType.double);
  }

  Future<void> updateSidewayPanelRequireClick(bool v) async {
    set(state.copyWith(sidewayPanelRequireClick: v));
    await _saveSliderRow('requireClick', v, SettingValueType.bool);
    if (v) {
      try {
        usePlayerUiStore().updateIsPanelClickArmed(false);
      } catch (_) {}
    }
  }

  /// Desktop corner-hide direction (`slider.cornerHideMode`).
  Future<void> updateSidePanelCornerHideMode(
      SidePanelCornerHideMode mode) async {
    set(state.copyWith(sidePanelCornerHideMode: mode));
    await _saveSliderRow(
        'cornerHideMode', mode.name, SettingValueType.enumeration);
  }

  /// Phone corner-hide direction (`slider.phoneCornerHideMode`).
  ///
  /// Separate from [updateSidePanelCornerHideMode] so the two platforms can
  /// never overwrite one row, mirroring the `posH` / `phonePosH` split.
  Future<void> updateMobileSidePanelCornerHideMode(
      SidePanelCornerHideMode mode) async {
    set(state.copyWith(mobileSidePanelCornerHideMode: mode));
    await _saveSliderRow(
        'phoneCornerHideMode', mode.name, SettingValueType.enumeration);
  }

  /// Rehydrates the sideway-panel anchor rows onto [base].
  /// Metadata-mode-only; corrupt/unknown rows degrade to [base] untouched.
  /// Phone uses screen % (widthPct/heightPct), desktop uses absolute px (widthPx/heightPx).
  /// Phone anchor `phonePosH` is isolated from desktop `posH/posV`; both are
  /// kept so switching platforms never loses data.
  Future<AppState> applySliderRows(AppState base,
      {Map<String, String>? prefetched}) async {
    if (!base.useMetadataSettings || !MetaSettingsModule.ready) return base;
    final Map<String, String> rows =
        prefetched ?? await MetaSettingsModule.loadSliderRows();
    if (rows.isEmpty) {
      final bool isPhone = isMobilePlatform;
      return base.copyWith(
        phoneSidePositionH: PhoneSidePositionH.right,
        mobileSidePositionH: PhoneSidePositionH.right,
        sidewayPanelWidthPct: 40.0,
        sidewayPanelHeightPct: 90.0,
        sidewayPanelWidthPx: isPhone ? base.sidewayPanelWidthPx : 380.0,
        sidewayPanelHeightPx: isPhone ? base.sidewayPanelHeightPx : 420.0,
      );
    }
    T? enm<T extends Enum>(String? raw, List<T> values) {
      if (raw == null) return null;
      for (final v in values) {
        if (v.name == raw) return v;
      }
      return null;
    }

    double? pct(String? raw) {
      final double? v = raw == null ? null : double.tryParse(raw);
      if (v == null || v.isNaN) return null;
      return _clampPanelPct(v);
    }

    double? pxW(String? raw) {
      final double? v = raw == null ? null : double.tryParse(raw);
      if (v == null || v.isNaN) return null;
      return _clampPanelPxW(v);
    }

    double? pxH(String? raw) {
      final double? v = raw == null ? null : double.tryParse(raw);
      if (v == null || v.isNaN) return null;
      return _clampPanelPxH(v);
    }

    final bool hasPct =
        rows.containsKey('widthPct') || rows.containsKey('heightPct');
    double? clamp01(String? raw) {
      final double? v = raw == null ? null : double.tryParse(raw);
      if (v == null || v.isNaN) return null;
      return v.clamp(0.0, 1.0).toDouble();
    }

    double? handleInset(String? raw) {
      final double? v = raw == null ? null : double.tryParse(raw);
      if (v == null || v.isNaN) return null;
      return _clampHandleInset(v);
    }

    double? handleRadius(String? raw) {
      final double? v = raw == null ? null : double.tryParse(raw);
      if (v == null || v.isNaN) return null;
      return _clampHandleRadius(v);
    }

    // New phone key: falls back to old posH center→right.
    PhoneSidePositionH? phoneH =
        enm(rows['phonePosH'], PhoneSidePositionH.values);
    if (phoneH != null && phoneH == PhoneSidePositionH.center)
      phoneH = PhoneSidePositionH.right;
    if (phoneH == null) {
      final PhoneSidePositionH? legacyH =
          enm(rows['posH'], PhoneSidePositionH.values);
      if (legacyH != null)
        phoneH = legacyH == PhoneSidePositionH.center
            ? PhoneSidePositionH.right
            : legacyH;
    }
    return base.copyWith(
      phoneSidePositionH: enm(rows['posH'], PhoneSidePositionH.values) ??
          base.phoneSidePositionH,
      phoneSidePositionV: enm(rows['posV'], PhoneSidePositionV.values) ??
          base.phoneSidePositionV,
      mobileSidePositionH: phoneH ?? base.mobileSidePositionH,
      sidewayPanelWidthPct:
          pct(rows['widthPct']) ?? (hasPct ? base.sidewayPanelWidthPct : 40.0),
      sidewayPanelHeightPct: pct(rows['heightPct']) ??
          (hasPct ? base.sidewayPanelHeightPct : 90.0),
      sidewayPanelWidthPx: pxW(rows['widthPx']) ?? base.sidewayPanelWidthPx,
      sidewayPanelHeightPx: pxH(rows['heightPx']) ?? base.sidewayPanelHeightPx,
      circlePosX: clamp01(rows['circlePosX']) ?? base.circlePosX,
      circlePosY: clamp01(rows['circlePosY']) ?? base.circlePosY,
      sidewayBarPos: clamp01(rows['barPos']) ?? base.sidewayBarPos,
      sidewayHandleInsetH:
          handleInset(rows['handleInsetH']) ?? base.sidewayHandleInsetH,
      sidewayHandleInsetV:
          handleInset(rows['handleInsetV']) ?? base.sidewayHandleInsetV,
      sidewayHandleRadiusH:
          handleRadius(rows['handleRadiusH']) ?? base.sidewayHandleRadiusH,
      sidewayHandleRadiusV:
          handleRadius(rows['handleRadiusV']) ?? base.sidewayHandleRadiusV,
      sidewayPanelRequireClick: rows.containsKey('requireClick')
          ? ValueCodec.decodeBool(rows['requireClick']!,
              fallback: base.sidewayPanelRequireClick)
          : base.sidewayPanelRequireClick,
      sidePanelCornerHideMode:
          enm(rows['cornerHideMode'], SidePanelCornerHideMode.values) ??
              base.sidePanelCornerHideMode,
      // New phone key; falls back to the old shared row so an install that
      // picked a direction before the split keeps hiding the way it did. All
      // three values are legal on a phone (its anchor is always a bottom
      // corner), so there is nothing to normalise the way `phonePosH` folds
      // `center` away. The fallback is read-only: the next phone write stores
      // its own row and the platforms are independent from then on.
      mobileSidePanelCornerHideMode: enm(
              rows['phoneCornerHideMode'], SidePanelCornerHideMode.values) ??
          enm(rows['cornerHideMode'], SidePanelCornerHideMode.values) ??
          base.mobileSidePanelCornerHideMode,
      sidePanelDialogOffset: (() {
        final String? raw = rows['dialogOffset'];
        if (raw == null) return base.sidePanelDialogOffset;
        try {
          final String decoded = ValueCodec.decodeJson(raw)?.toString() ?? raw;
          final parts = decoded.split(',');
          if (parts.length == 2) {
            final double? x = double.tryParse(parts[0]);
            final double? y = double.tryParse(parts[1]);
            if (x != null && y != null)
              return Offset(x.clamp(0.05, 0.95), y.clamp(0.05, 0.95));
          }
        } catch (_) {}
        return base.sidePanelDialogOffset;
      })(),
    );
  }

  /// Rehydrates the window/dock overrides onto [base].
  /// Metadata-mode-only; malformed rows degrade to [base] untouched.
  Future<AppState> applyWindowRows(AppState base,
      {Map<String, String>? prefetched}) async {
    if (!base.useMetadataSettings || !MetaSettingsModule.ready) return base;
    final Map<String, String> rows =
        prefetched ?? await MetaSettingsModule.loadWindowRows();
    if (rows.isEmpty) return base;

    T? enm<T extends Enum>(String? raw, List<T> values) {
      if (raw == null) return null;
      for (final v in values) {
        if (v.name == raw) return v;
      }
      return null;
    }

    final mode = enm(rows['playlistPanelMode'], PlaylistPanelMode.values);
    final behavior =
        enm(rows['sideFullscreenBehavior'], SideFullscreenBehavior.values);
    final popupTheme =
        enm(rows['playlistPopupTheme'], PlaylistPopupTheme.values);
    final dockTheme = enm(rows['playlistDockTheme'], PlaylistDockTheme.values);
    final fitMode = enm(rows['fitMode'], WindowFitMode.values);
    // The pre-split row an already-upgraded install wrote. It is a READ-ONLY
    // migration seed: whichever profiles have no row of their own inherit it, so
    // the split costs existing users nothing and needs no schema migration.
    final legacyQueueLayout =
        enm(rows['scenarioQueueLayout'], ScenarioQueueLayout.values);
    final visibleRaw = rows['playlistPanelVisible'];
    final widthRaw = rows['playlistPanelWidth'];
    final edgeRaw = rows['fullscreenDockEdgeRevealPct'];
    final sideIsolationRaw = rows['sidePanelIsolationPct'];
    final linearIsolationRaw = rows['linearBarIsolationPct'];

    double? width;
    if (widthRaw != null) {
      final double? parsed = double.tryParse(widthRaw);
      if (parsed != null && !parsed.isNaN) width = parsed.clamp(240.0, 600.0);
    }

    double? edgePct;
    if (edgeRaw != null) {
      final double? parsed = double.tryParse(edgeRaw);
      if (parsed != null) edgePct = clampFullscreenDockEdgePct(parsed);
    }

    double? sideIsolation;
    if (sideIsolationRaw != null) {
      final double? parsed = double.tryParse(sideIsolationRaw);
      if (parsed != null) sideIsolation = clampSidePanelIsolationPct(parsed);
    }

    double? linearIsolation;
    if (linearIsolationRaw != null) {
      final double? parsed = double.tryParse(linearIsolationRaw);
      if (parsed != null) linearIsolation = clampLinearBarIsolationPct(parsed);
    }

    bool? visible;
    if (visibleRaw != null)
      visible = ValueCodec.decodeBool(visibleRaw,
          fallback: base.playlistPanelVisible);
    final keepRaw = rows['keepInBounds'];
    final bool? keepInBounds = keepRaw == null
        ? null
        : ValueCodec.decodeBool(keepRaw, fallback: base.keepWindowInBounds);

    // A missing row must NOT force the default: `false` is a legitimate stored
    // value here, so only a present row may override the base.
    final crumbRaw = rows['scenarioQueueShowBreadcrumb'];
    final bool? showQueueBreadcrumb = crumbRaw == null
        ? null
        : ValueCodec.decodeBool(crumbRaw,
            fallback: base.scenarioQueueShowBreadcrumb);

    var next = base;
    for (final profile in ScenarioQueueProfile.values) {
      next = next.withScenarioQueueLayout(
        profile,
        enm(rows[profile.layoutRow], ScenarioQueueLayout.values) ??
            legacyQueueLayout ??
            next.scenarioQueueLayoutFor(profile),
      );
      final Offset? offset = _decodeFraction(rows[profile.barOffsetRow]);
      if (offset != null) {
        next = next.withScenarioQueueBarOffset(profile, offset);
      }
    }

    return next.copyWith(
      playlistPanelMode: mode ?? base.playlistPanelMode,
      sideFullscreenBehavior: behavior ?? base.sideFullscreenBehavior,
      playlistPopupTheme: popupTheme ?? base.playlistPopupTheme,
      playlistDockTheme: dockTheme ?? base.playlistDockTheme,
      windowFitMode: fitMode ?? base.windowFitMode,
      playlistPanelVisible: visible ?? base.playlistPanelVisible,
      playlistPanelWidth: width ?? base.playlistPanelWidth,
      fullscreenDockEdgeRevealPct: edgePct ?? base.fullscreenDockEdgeRevealPct,
      sidePanelIsolationPct: sideIsolation ?? base.sidePanelIsolationPct,
      linearBarIsolationPct: linearIsolation ?? base.linearBarIsolationPct,
      keepWindowInBounds: keepInBounds ?? base.keepWindowInBounds,
      scenarioQueueShowBreadcrumb:
          showQueueBreadcrumb ?? base.scenarioQueueShowBreadcrumb,
    );
  }

  // ── Desktop keybind overrides (PotPlayer scheme customization) ───────────
  // AUX `keybind.` row `overrides` — JsonKey-excluded, desktop-only.

  Future<void> _saveKeybindRow(
      String field, Object? value, SettingValueType type) async {
    if (!state.useMetadataSettings || !MetaSettingsModule.ready) return;
    final String? encoded = ValueCodec.encode(type, value);
    if (encoded == null) return;
    await MetaSettingsModule.saveKeybindRow(field, encoded);
  }

  Future<void> updateKeybindOverridesJson(String jsonStr) async {
    set(state.copyWith(keybindOverridesJson: jsonStr));
    // Persist as decoded map via json ValueCodec so row stores clean object,
    // not a double-encoded string.
    try {
      final Object? decoded = json.decode(jsonStr);
      if (decoded is Map) {
        await _saveKeybindRow('overrides', decoded, SettingValueType.json);
        return;
      }
    } catch (_) {}
    await _saveKeybindRow('overrides', jsonStr, SettingValueType.string);
  }

  Future<void> setKeybindForAction(
    String actionName,
    List<dynamic> combosJson,
  ) async {
    final Map<String, dynamic> current =
        _decodeKeybindJson(state.keybindOverridesJson);
    current[actionName] = combosJson;
    final String next = json.encode(current);
    await updateKeybindOverridesJson(next);
  }

  Map<String, dynamic> _decodeKeybindJson(String raw) {
    try {
      final Object? decoded = json.decode(raw);
      if (decoded is Map<String, dynamic>)
        return Map<String, dynamic>.from(decoded);
      if (decoded is Map) return Map<String, dynamic>.from(decoded as Map);
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<void> removeKeybindForAction(String actionName) async {
    final Map<String, dynamic> current =
        _decodeKeybindJson(state.keybindOverridesJson);
    if (!current.containsKey(actionName)) return;
    current.remove(actionName);
    await updateKeybindOverridesJson(json.encode(current));
  }

  Future<void> resetAllKeybinds() async {
    await updateKeybindOverridesJson('{}');
  }

  /// Rehydrates the keybind overrides onto [base].
  /// Metadata-mode-only; malformed rows degrade to [base] untouched.
  Future<AppState> applyKeybindRows(AppState base,
      {Map<String, String>? prefetched}) async {
    if (!base.useMetadataSettings || !MetaSettingsModule.ready) return base;
    final Map<String, String> rows =
        prefetched ?? await MetaSettingsModule.loadKeybindRows();
    final String? raw = rows['overrides'];
    if (raw == null) return base;
    try {
      final Object? decoded = ValueCodec.decodeJson(raw);
      if (decoded is Map) {
        return base.copyWith(keybindOverridesJson: json.encode(decoded));
      }
      if (decoded is String) {
        final Object? inner = json.decode(decoded);
        if (inner is Map)
          return base.copyWith(keybindOverridesJson: json.encode(inner));
        return base.copyWith(keybindOverridesJson: decoded);
      }
      // Fallback: raw may be plain string json.
      final Object? direct = json.decode(raw);
      if (direct is Map)
        return base.copyWith(keybindOverridesJson: json.encode(direct));
      return base;
    } catch (_) {
      return base;
    }
  }

  /// Rehydrates the keyboard OSD overrides onto [base].
  ///
  /// Metadata-mode-only; malformed rows degrade to [base] untouched.
  Future<AppState> applyOsdRows(AppState base,
      {Map<String, String>? prefetched}) async {
    if (!base.useMetadataSettings || !MetaSettingsModule.ready) return base;
    final Map<String, String> rows =
        prefetched ?? await MetaSettingsModule.loadOsdRows();
    if (rows.isEmpty) return base;

    bool? b(String? raw, bool fallback) =>
        raw == null ? null : ValueCodec.decodeBool(raw, fallback: fallback);

    T? enm<T extends Enum>(String? raw, List<T> values) {
      if (raw == null) return null;
      for (final v in values) {
        if (v.name == raw) return v;
      }
      return null;
    }

    int? clampedInt(String? raw, int min, int max) {
      if (raw == null) return null;
      final int? v = int.tryParse(raw);
      if (v == null) return null;
      return v.clamp(min, max);
    }

    return base.copyWith(
      osdEnabled: b(rows['osdEnabled'], base.osdEnabled) ?? base.osdEnabled,
      osdVisibilityMode:
          enm(rows['osdVisibilityMode'], OsdVisibilityMode.values) ??
              base.osdVisibilityMode,
      osdHAlign: enm(rows['osdHAlign'], OsdHAlign.values) ?? base.osdHAlign,
      osdVAlign: enm(rows['osdVAlign'], OsdVAlign.values) ?? base.osdVAlign,
      osdLayout: enm(rows['osdLayout'], OsdLayout.values) ?? base.osdLayout,
      osdDurationMs:
          clampedInt(rows['osdDurationMs'], 800, 5000) ?? base.osdDurationMs,
    );
  }

  AppState _decodeDialRing(Map<String, String> rows, AppState base) {
    // Malformed rows degrade to the base value — never NaN into geometry.
    double? pct(String? raw) {
      final double? v = raw == null ? null : double.tryParse(raw);
      if (v == null || v.isNaN) return null;
      return clampRingDialPct(v);
    }

    double? slotT(String? raw) {
      final double? v = raw == null ? null : double.tryParse(raw);
      if (v == null || v.isNaN) return null;
      return clampSlotT(v);
    }

    double? radius(String? raw) {
      final double? v = raw == null ? null : double.tryParse(raw);
      if (v == null || v.isNaN) return null;
      return clampRingDialOuterRadius(v);
    }

    RingDialPalette? palette(String? raw) {
      if (raw == null) return null;
      for (final p in RingDialPalette.values) {
        if (p.name == raw) return p;
      }
      return null;
    }

    DialSide? side(String? raw) {
      if (raw == null) return null;
      for (final s in DialSide.values) {
        if (s.name == raw) return s;
      }
      return null;
    }

    RingDialAssignment? assignment(String? raw) {
      if (raw == null) return null;
      for (final a in RingDialAssignment.values) {
        if (a.name == raw) return a;
      }
      return null;
    }

    bool? showAxis(String? raw) {
      if (raw == '1' || raw == 'true') return true;
      if (raw == '0' || raw == 'false') return false;
      return null;
    }

    final double outer =
        radius(rows['ringDialOuterRadius']) ?? base.ringDialOuterRadius;

    // Migrate legacy hideInner key → hideChunk.
    final String? hideChunkRaw = rows['ringDialHideChunkWhenUnchunked'] ??
        rows['ringDialHideInnerWhenUnchunked'];

    return base.copyWith(
      ringDialPalette: palette(rows['ringDialPalette']) ?? base.ringDialPalette,
      ringDialHeightPct:
          pct(rows['ringDialHeightPct']) ?? base.ringDialHeightPct,
      ringDialSide: side(rows['ringDialSide']) ?? base.ringDialSide,
      ringDialAssignment:
          assignment(rows['ringDialAssignment']) ?? base.ringDialAssignment,
      ringDialHideChunkWhenUnchunked:
          showAxis(hideChunkRaw) ?? base.ringDialHideChunkWhenUnchunked,
      ringDialVmProgressLock: showAxis(rows['ringDialVmProgressLock']) ??
          base.ringDialVmProgressLock,
      ringDialRingSlotT:
          slotT(rows['ringDialRingSlotT']) ?? base.ringDialRingSlotT,
      ringDialOuterRadius: outer,
      ringDialInnerRadius: rows.containsKey('ringDialInnerRadius')
          ? clampRingDialInnerRadius(
              double.tryParse(rows['ringDialInnerRadius']!) ??
                  base.ringDialInnerRadius,
              outerFactor: outer,
            )
          : clampRingDialInnerRadius(
              base.ringDialInnerRadius,
              outerFactor: outer,
            ),
    );
  }

  /// Single source of truth for post-load normalization. Runs on BOTH paths
  /// (legacy blob and metadata rows) so behavior stays identical.
  AppState _normalizeLoaded(AppState appState) {
    var normalized = appState.copyWith(
      autoPlay: false,
      // Clamp ON READ: a browser page size persisted by an older build (the
      // prompt used to allow 100000) would otherwise materialize a huge page
      // on upgrade.
      storageBrowserPageSize:
          clampPageSize(appState.storageBrowserPageSize),
    );

    if (!normalized.reuseLastOrientation) {
      normalized = normalized.copyWith(
        runtimeOrientation: normalized.preferredOrientation,
      );
    }

    // Always normalize layouts (not only when empty)
    // Migrate legacy hand keys → side keys
    final migratedProfiles =
        Map<String, Map<GestureIntent, GestureLayout>>.from(
            normalized.gestureLayoutProfiles);
    if (migratedProfiles.containsKey('rightHand') &&
        !migratedProfiles.containsKey(kLayoutRegionRightSide)) {
      migratedProfiles[kLayoutRegionRightSide] =
          migratedProfiles.remove('rightHand')!;
    } else {
      migratedProfiles.remove('rightHand');
    }
    if (migratedProfiles.containsKey('leftHand') &&
        !migratedProfiles.containsKey(kLayoutRegionLeftSide)) {
      migratedProfiles[kLayoutRegionLeftSide] =
          migratedProfiles.remove('leftHand')!;
    } else {
      migratedProfiles.remove('leftHand');
    }
    if (migratedProfiles.containsKey('tagPlay') &&
        !migratedProfiles.containsKey(kLayoutRegion)) {
      // tagPlay was unified into region
      migratedProfiles.remove('tagPlay');
    } else {
      migratedProfiles.remove('tagPlay');
    }
    migratedProfiles.remove('tagPlayRightSide');
    migratedProfiles.remove('tagPlayLeftSide');
    normalized = normalized.copyWith(gestureLayoutProfiles: migratedProfiles);

    // Migrate legacy enum values hand → side
    if (normalized.landscapeGestureProfile ==
        LandscapeGestureProfile.rightHand) {
      normalized = normalized.copyWith(
          landscapeGestureProfile: LandscapeGestureProfile.rightSide);
    } else if (normalized.landscapeGestureProfile ==
        LandscapeGestureProfile.leftHand) {
      normalized = normalized.copyWith(
          landscapeGestureProfile: LandscapeGestureProfile.leftSide);
    } else if (normalized.landscapeGestureProfile ==
        LandscapeGestureProfile.tagPlay) {
      normalized = normalized.copyWith(
          landscapeGestureProfile: LandscapeGestureProfile.region);
    }
    // Migrate legacy enum values hand → side. This is the ONLY place a
    // deprecated one-handed mode is read: the members stay parseable so an old
    // blob loads, and are folded to their replacements before anything else
    // sees the state.
    if (normalized.phoneLandscapeUseMode == PhoneLandscapeUseMode.rightHanded) {
      normalized = normalized.copyWith(
          phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide);
    } else if (normalized.phoneLandscapeUseMode ==
        PhoneLandscapeUseMode.leftHanded) {
      normalized = normalized.copyWith(
          phoneLandscapeUseMode: PhoneLandscapeUseMode.leftSide);
    }
    // Fold a stale placement back onto the mode — GATE-ON ONLY. The two fields
    // encode the same left/right decision, and a blob written before the
    // pairing existed can hold a `circleLeft` next to a `rightSide` mode. Under
    // the gate the mode is the authority, so the fold is safe and needed
    // (otherwise a stale corner still steers resolveControlPanelAnchor). Gate
    // OFF is the frozen legacy path where the two were chosen independently —
    // rewriting there would change installs that work today, so it is left
    // exactly as stored.
    if (normalized.useMetadataSettings &&
        normalized.phoneLandscapeSliderType !=
            sliderTypeForUseMode(normalized.phoneLandscapeUseMode)) {
      normalized = normalized.copyWith(
        phoneLandscapeSliderType:
            sliderTypeForUseMode(normalized.phoneLandscapeUseMode),
      );
    }

    // Requirement #6: arc/timeLens/snake are FULLY retired — old blobs fold
    // into the classic circle slider on load, so the dead designs can never
    // render again (belt-and-braces with resolveScrubberSlot's degradation).
    if (normalized.phoneOneHandedScrubberKind == PhoneSideScrubberKind.arc ||
        normalized.phoneOneHandedScrubberKind ==
            PhoneSideScrubberKind.timeLens ||
        normalized.phoneOneHandedScrubberKind == PhoneSideScrubberKind.snake) {
      // ignore: deprecated_member_use_from_same_package
      normalized = normalized.copyWith(
        // ignore: deprecated_member_use_from_same_package
        phoneOneHandedScrubberKind: PhoneSideScrubberKind.classic,
      );
    }

    final normalizedProfiles = <String, Map<GestureIntent, GestureLayout>>{};

    // 4 meta keys: portrait + landscape region + right/left side.
    // Debug dev build: one-time overwrite — any missing key is seeded from
    // defaults and surviving user edits overlay; no careful preserve of the
    // former portrait==landscape alias.
    final metaKeys = [
      kLayoutRegionPortrait,
      kLayoutRegion,
      kLayoutRegionRightSide,
      kLayoutRegionLeftSide,
    ];
    // One-time split: if old data only had kLayoutRegion, seed portrait from it
    // so a developer sees continuity after the split (otherwise portrait would
    // look like a fresh default while landscape keeps edits).
    if (!migratedProfiles.containsKey(kLayoutRegionPortrait) &&
        migratedProfiles.containsKey(kLayoutRegion)) {
      migratedProfiles[kLayoutRegionPortrait] =
          Map<GestureIntent, GestureLayout>.from(
              migratedProfiles[kLayoutRegion]!);
    }
    // Grid invariant enforcement: stored layouts that are not strict n×m
    // grids (legacy blobs — e.g. the old straddling tag-strip doubleTap)
    // reset to the current default grid; conformant user edits survive.
    final gridCleaned = dropNonGridLayouts(
      profiles: migratedProfiles,
      defaults: defaultGestureLayoutProfiles,
    );
    for (final key in metaKeys) {
      final defaults = defaultGestureLayoutProfiles[key]!;
      final existing = gridCleaned[key] ?? {};
      normalizedProfiles[key] = {
        ...defaults,
        ...migrateEmptyLongPressPanVertical(existing, defaults),
      };
    }
    gestureAreaKeyLog
        .i('Normalized layout keys: ${normalizedProfiles.keys.toList()}');

    return normalized.copyWith(
      gestureLayoutProfiles: normalizedProfiles,
    );
  }

  @override
  Future<void> save(AppState state) async {
    // Durability gate (same as the storage store): persisting the default
    // state of a store whose load never succeeded would wipe the user's
    // real settings (e.g. after a corrupt blob or a down backend).
    if (!loadOk) {
      areaKeyLog.w('skip save: app store never loaded successfully');
      return;
    }
    // Legacy blob ONLY — deliberately DAO-free. The metadata mirror is
    // written by [_persist] (the funnel tail) per PersistPolicy, so blob and
    // rows stay coherent wherever the write came from. Blob writes continue
    // under metadata mode (sync gate ON) so gate-off / downgrade rollbacks
    // stay lossless.
    try {
      final storage = getKvStore();

      await storage.write(key: 'app_state', value: json.encode(state.toJson()));
    } catch (e) {
      areaKeyLog.e('Error saving AppState: $e');
    }
  }

  @override
  void onReady() {
    // No backend switching here: AppStore is constructed on the first frame,
    // before BootstrapGate has wired the database. `applyConfiguredBackends()`
    // runs once the DB is ready (see completeStartupInitialization) so the
    // storage/play-queue stores switch to the configured backends without
    // racing the DB wiring.
  }

  /// Switches the storage/play-queue stores to the backends implied by the
  /// persisted legacy-vs-metadata flag. Idempotent.
  ///
  /// MUST run after `DbModule.init`: the query backend dereferences the DB.
  /// Called from `completeStartupInitialization` once the DB is wired. The
  /// previous design awaited readiness inside [onReady], which deadlocked
  /// widget tests under FakeAsync.
  Future<void> applyConfiguredBackends() async {
    // Defensive: never touch the DB-backed query backend before the DB wiring
    // finished. Startup awaits the DB before calling this; the guard keeps a
    // future re-ordering from silently breaking the query backend.
    await DbModule.ready;
    final storageStore = useStorageStore();
    await storageStore.switchBackend(state.useLegacyStoragePersistence);
    final playQueueStore = usePlayQueueStore();
    await playQueueStore.switchBackend(state.useLegacyStoragePersistence);
  }

  Future<void> importFromJson(Map<String, dynamic> json) async {
    var imported = AppState.fromJson(json);

    imported = imported.copyWith(
      autoPlay: false,
      // An imported settings bundle may carry an out-of-range page size; clamp
      // it here so the import boundary matches the load boundary.
      storageBrowserPageSize:
          clampPageSize(imported.storageBrowserPageSize),
    );

    if (!imported.reuseLastOrientation) {
      imported = imported.copyWith(
        runtimeOrientation: imported.preferredOrientation,
      );
    }

    // Same round-trip loss as applyJsonField: the bundle carries no
    // JsonKey-excluded (AUX-backed) fields, so re-hydrate those domains from
    // the DB instead of publishing defaults over the live state.
    imported = await applyAuxDomains(imported);

    set(imported);
    await _persist(imported);
  }

  Map<String, dynamic> exportToJson() {
    return state.toJson()
      ..remove('runtimeOrientation')
      ..remove('autoPlay');
  }
}

AppStore useAppStore() => create(() => AppStore());
