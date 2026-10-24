import 'dart:convert';

import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/control_group/model/control_group_state.dart';
import 'package:iris/features/control_group/model/enum/player_control_group.dart';
import 'package:iris/store/kv/kv_keys.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/store/persistent_store.dart';
import 'package:iris/utils/app_instance.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyStore);

/// State holder of the one-handed bottom control-group switch.
///
/// Persisted through the KV backend so the remembered group, the floating
/// button's visibility and its position survive app restarts. The store holds
/// no player/engine reference — the control bar reads
/// [ControlGroupState.group] directly and the toggle entry points call
/// [cycleGroup].
///
/// Phones split the floater's visibility per orientation (portrait ON /
/// landscape OFF by default); desktop is a single [floatingButtonDesktop] flag
/// that ships ON. A stored value always wins, so an explicit user choice is
/// never overridden.
class ControlGroupStore extends PersistentStore<ControlGroupState> {
  ControlGroupStore() : super(const ControlGroupState());

  /// Shared-config store: an extra window's shutdown snapshot may predate a
  /// change another window made (see [PersistentStore.persistOnDispose]).
  @override
  bool get persistOnDispose => AppInstance.isPrimary;

  static const String _key = KvKeys.controlGroupState;

  /// Selects a group (no-op on the current one) and persists it.
  Future<void> setGroup(PlayerControlGroup group) async {
    if (state.group == group) return;
    set(state.copyWith(group: group));
    await save(state);
  }

  /// Advances to the next group in declaration order and persists it.
  Future<void> cycleGroup() => setGroup(nextPlayerControlGroup(state.group));

  /// Whether the floating switch should be present for [isLandscape].
  ///
  /// PHONE-only: desktop uses [ControlGroupState.floatingButtonDesktop] and
  /// ignores the orientation.
  bool isFloatingButtonVisible({required bool isLandscape}) => isLandscape
      ? state.floatingButtonLandscape
      : state.floatingButtonPortrait;

  /// Writes the floating switch visibility for ONE orientation, leaving the
  /// other untouched (the two are independent settings).
  Future<void> setFloatingButtonVisible({
    required bool isLandscape,
    required bool visible,
  }) async {
    final ControlGroupState next = isLandscape
        ? state.copyWith(floatingButtonLandscape: visible)
        : state.copyWith(floatingButtonPortrait: visible);
    if (next == state) return;
    set(next);
    await save(state);
  }

  /// Writes the DESKTOP floating switch visibility (orientation-independent).
  Future<void> setDesktopFloatingButtonVisible({required bool visible}) async {
    if (state.floatingButtonDesktop == visible) return;
    set(state.copyWith(floatingButtonDesktop: visible));
    await save(state);
  }

  /// Commits the floating button position once, at the end of a drag.
  /// Fractions are clamped to the host box; drag frames stay memory-only.
  Future<void> setFloatingButtonFraction(double x, double y) async {
    final double cx = x.clamp(0.0, 1.0).toDouble();
    final double cy = y.clamp(0.0, 1.0).toDouble();
    if (state.floatingX == cx && state.floatingY == cy) return;
    set(state.copyWith(floatingX: cx, floatingY: cy));
    await save(state);
  }

  @override
  Future<ControlGroupState?> load() async {
    try {
      final String? raw = await getKvStore().read(key: _key);
      if (raw == null || raw.isEmpty) return null;
      final Map<String, dynamic> map = json.decode(raw) as Map<String, dynamic>;
      // Upgrade JSON written before the orientation split. The legacy single
      // toggle only ever governed the PHONE portrait floater — it carried no
      // landscape concept — and its persisted value may be the OLD platform
      // default rather than an explicit choice, so it cannot be trusted to turn
      // landscape ON. Honor it in PORTRAIT only; landscape keeps the new,
      // deliberate default (OFF). A never-written key falls through untouched.
      if (map.containsKey('floatingButtonEnabled') &&
          !map.containsKey('floatingButtonPortrait') &&
          !map.containsKey('floatingButtonLandscape')) {
        final bool legacy = map['floatingButtonEnabled'] as bool? ?? false;
        map['floatingButtonPortrait'] = legacy;
      }
      return ControlGroupState.fromJson(map);
    } catch (e) {
      _log.e('Error loading ControlGroupState: $e');
      // A decode failure is a load failure: rethrow so PersistentStore keeps
      // its default state and disables writes (never clobber good data).
      rethrow;
    }
  }

  @override
  Future<void> save(ControlGroupState s) async {
    // Multi-window: this is ONE whole-state KV value. An extra window's copy
    // predates whatever a sibling wrote since it loaded, so writing it back
    // reverts the shared `group` / visibility choices — dragging the floating
    // button is enough to roll the primary's group back. Same rule as
    // AppState's blob gate: only the primary persists shared config; an extra
    // window keeps its change in memory for this run.
    if (!AppInstance.isPrimary) {
      _log.w('ControlGroupState kept in memory (extra window)');
      return;
    }
    try {
      await getKvStore().write(key: _key, value: json.encode(s.toJson()));
    } catch (e) {
      _log.e('Error saving ControlGroupState: $e');
    }
  }
}

ControlGroupStore useControlGroupStore() => create(() => ControlGroupStore());
