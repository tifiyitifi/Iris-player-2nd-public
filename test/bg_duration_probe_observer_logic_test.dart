import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/view/bg_duration_probe_observer.dart';
import 'package:iris/models/file.dart';

/// The duration probe is async (platform demux), so the queue can be replaced
/// while a pass is in flight. Publishing that pass's outcome would flag the NEW
/// queue's rows with the OLD queue's keys — `bgProbeOutcomeStillApplies` is the
/// gate that keeps the stale outcome out (see the observer's `_probe`).
FileItem _f(String key) =>
    FileItem(name: key, uri: 'file:///$key', path: [key]);

void main() {
  group('bgProbeOutcomeStillApplies', () {
    test('the same membership may publish', () {
      expect(
        bgProbeOutcomeStillApplies(
          passQueue: <FileItem>[_f('a'), _f('b')],
          liveQueue: <FileItem>[_f('a'), _f('b')],
        ),
        isTrue,
      );
    });

    test('a replaced queue drops the stale outcome', () {
      expect(
        bgProbeOutcomeStillApplies(
          passQueue: <FileItem>[_f('a'), _f('b')],
          liveQueue: <FileItem>[_f('c')],
        ),
        isFalse,
      );
    });

    test('a removed member is a different queue', () {
      expect(
        bgProbeOutcomeStillApplies(
          passQueue: <FileItem>[_f('a'), _f('b')],
          liveQueue: <FileItem>[_f('a')],
        ),
        isFalse,
      );
    });

    test('a reordered queue is a different membership fingerprint', () {
      expect(
        bgProbeOutcomeStillApplies(
          passQueue: <FileItem>[_f('a'), _f('b')],
          liveQueue: <FileItem>[_f('b'), _f('a')],
        ),
        isFalse,
      );
    });
  });
}
