import 'package:flutter_test/flutter_test.dart';
import 'package:iris/hooks/player/media_info_writeback.dart';

/// Attribution contract for the lazy `media_nodes` write-back.
///
/// On a track switch the hook's `file` (and therefore its media key) changes
/// BEFORE the backend resets `duration` / `videoParams` — `open()` is async and
/// runs from another effect. Without an attribution guard the PREVIOUS file's
/// duration and dimensions were written onto the NEW file's row, and the
/// write-once gate then dropped the real values for the rest of the session
/// (observed in the field: every row carried its predecessor's duration, e.g.
/// a 44 s clip row showing the 5:47 of the file played before it).
void main() {
  group('MediaInfoWritebackGate.belongsToOpenFile', () {
    final gate = MediaInfoWritebackGate();

    test('denies while this file has not finished opening', () {
      // `open()` not completed yet: `duration` still describes the previous
      // media, so nothing may be attributed to `b`.
      expect(
        gate.belongsToOpenFile(mediaUri: 'b', openedUri: null),
        isFalse,
      );
    });

    test('denies values still belonging to the previous file', () {
      expect(
        gate.belongsToOpenFile(mediaUri: 'b', openedUri: 'a'),
        isFalse,
      );
    });

    test('allows only the file the player actually opened', () {
      expect(
        gate.belongsToOpenFile(mediaUri: 'b', openedUri: 'b'),
        isTrue,
      );
    });

    test('a null media uri (no current file) never writes', () {
      expect(gate.belongsToOpenFile(mediaUri: null, openedUri: null), isFalse);
      expect(gate.belongsToOpenFile(mediaUri: null, openedUri: 'a'), isFalse);
    });
  });

  group('mediaInfoCorrects', () {
    test('an unchanged duration/dimension triple corrects nothing', () {
      expect(
        mediaInfoCorrects(
          storedDurationMs: 44153,
          storedWidth: 1920,
          storedHeight: 1080,
          durationMs: 44153,
          width: 1920,
          height: 1080,
        ),
        isFalse,
      );
    });

    test('a differing duration is a correction', () {
      // 44153 is the truth; the row was poisoned with another file's 347765.
      expect(
        mediaInfoCorrects(
          storedDurationMs: 347765,
          storedWidth: 1920,
          storedHeight: 1080,
          durationMs: 44153,
          width: 1920,
          height: 1080,
        ),
        isTrue,
      );
    });

    test('a differing dimension is a correction', () {
      expect(
        mediaInfoCorrects(
          storedDurationMs: 44153,
          storedWidth: 1728,
          storedHeight: 1080,
          durationMs: 44153,
          width: 1920,
          height: 1080,
        ),
        isTrue,
      );
    });

    test('filling an unknown value is a correction', () {
      expect(
        mediaInfoCorrects(
          storedDurationMs: null,
          storedWidth: null,
          storedHeight: null,
          durationMs: 44153,
          width: 1920,
          height: 1080,
        ),
        isTrue,
      );
    });
  });
}
