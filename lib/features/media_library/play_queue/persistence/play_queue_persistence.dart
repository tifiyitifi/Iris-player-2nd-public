import 'dart:convert';

import 'package:iris/models/store/play_queue_state.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/utils/logger.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyStore);

abstract class PlayQueuePersistence {
  Future<PlayQueueState?> load();
  Future<void> save(PlayQueueState state);
}

class LegacyPlayQueuePersistence implements PlayQueuePersistence {
  static const _key = 'playQueue_state';

  @override
  Future<PlayQueueState?> load() async {
    try {
      final storage = getSessionKvStore();
      final raw = await storage.read(key: _key);
      if (raw != null) {
        return PlayQueueState.fromJson(json.decode(raw));
      }
    } catch (e) {
      areaKeyLog.e('LegacyPlayQueuePersistence load error: $e');
    }
    return null;
  }

  @override
  Future<void> save(PlayQueueState state) async {
    try {
      final storage = getSessionKvStore();
      await storage.write(key: _key, value: json.encode(state.toJson()));
    } catch (e) {
      areaKeyLog.e('LegacyPlayQueuePersistence save error: $e');
    }
  }
}

class QueryPlayQueuePersistence implements PlayQueuePersistence {
  @override
  Future<PlayQueueState?> load() async => null;

  @override
  Future<void> save(PlayQueueState state) async {}
}
