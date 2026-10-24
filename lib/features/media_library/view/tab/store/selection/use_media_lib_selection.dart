import 'dart:convert';

import 'package:iris/store/kv/use_kv_store.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/selection/selection_controller.dart';
import 'package:iris/features/media_library/selection/selection_state.dart';
import 'package:iris/store/persistent_store.dart';

class MediaLibSelectionStore extends PersistentStore<SelectionState<String>> {
  MediaLibSelectionStore() : super(const SelectionState()) {
    _initController();
  }

  /// Window-scoped view state: the KV key is session-scoped, so two windows
  /// keep independent selections.

  static const _storageKey = 'media_lib_selection';

  late SelectionController<String> controller;

  void _initController() {
    controller = SelectionController<String>(
      // System libraries (per-storage `sys_<id>` plus the detached
      // `sys_detached`) are not selectable. This covers both conventions via
      // the `sys_` prefix instead of the legacy `local_lib` constant (D13).
      isSelectable: (id) => !id.startsWith('sys_'),
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

MediaLibSelectionStore useMediaLibSelectionStore() => create(() => MediaLibSelectionStore());
