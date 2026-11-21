import 'dart:async';
import 'dart:ui';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/models/player.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:provider/provider.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyMain);

void useAppLifecycle() {
  final context = useContext();

  AppLifecycleState? appLifecycleState = useAppLifecycleState();

  useEffect(() {
    try {
      if (appLifecycleState == AppLifecycleState.paused) {
        areaKeyLog.i('App lifecycle state: paused');
        final player = context.read<MediaPlayer>();
        unawaited(player.saveProgress());
        // Android destroys the Activity (and its Dart isolate) while a live
        // media_kit Player still holds an mpv wakeup callback; the next wakeup
        // then calls the deleted FFI callback and aborts the process
        // (media_kit #1477). An idle player is far less likely to wake up, so
        // pause while backgrounded. Mitigation only: the callback stays
        // registered until the process dies.
        if (isAndroid) unawaited(player.pause());
      }
    } catch (e) {
      areaKeyLog.e('App lifecycle state error: $e');
    }
    return;
  }, [appLifecycleState]);
}
