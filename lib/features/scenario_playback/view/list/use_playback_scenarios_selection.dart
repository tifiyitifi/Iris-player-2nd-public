import 'dart:convert';

import 'package:iris/store/kv/use_kv_store.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/selection/selection_controller.dart';
import 'package:iris/features/media_library/selection/selection_state.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/store/persistent_store.dart';

/// Persistent multi-select state for the Playback Scenario list tab.
///
/// Mirrors [MediaLibSelectionStore]. The system default scenario cannot be
/// selected.
class PlaybackScenariosSelectionStore
    extends PersistentStore<SelectionState<String>> {
  PlaybackScenariosSelectionStore() : super(const SelectionState()) {
    _initController();
  }

  /// Window-scoped view state: the KV key is session-scoped, so two windows
  /// keep independent selections.

  static const _storageKey = 'playback_scenarios_selection';

  late SelectionController<String> controller;

  void _initController() {
    controller = SelectionController<String>(
      isSelectable: (id) {
        final scenarios = usePlaybackScenarioStore().state.scenarios;
        for (final s in scenarios) {
          if (s.id == id) return s.type == ScenarioKind.userSaved;
        }
        return true;
      },
      initialState: state,
    );

    controller.addListener(() {
      set(controller.state);
      save(controller.state);
    });
  }

  @override
  Future<SelectionState<String>?> load() async {
    final storage = getSessionKvStore();
    final raw = await storage.read(key: _storageKey);

    if (raw == null) return null;
    return SelectionState<String>.fromJson(
      json.decode(raw),
      (v) => v as String,
    );
  }

  @override
  Future<void> save(SelectionState<String> state) async {
    final storage = getSessionKvStore();
    await storage.write(
      key: _storageKey,
      value: json.encode(
        state.toJson((v) => v),
      ),
    );
  }
}

PlaybackScenariosSelectionStore usePlaybackScenariosSelectionStore() =>
    create(() => PlaybackScenariosSelectionStore());
