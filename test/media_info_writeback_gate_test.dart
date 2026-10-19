import 'package:flutter_test/flutter_test.dart';
import 'package:iris/hooks/player/media_info_writeback.dart';

/// Regression coverage for the lazy `media_nodes` backfill mark.
///
/// The mark used to be a per-hook boolean, so once the FIRST file of a session
/// was written every later file's duration/dimensions were dropped (the gate
/// stayed "already written"). The mark is now keyed by the file.
void main() {
  group('MediaInfoWritebackGate', () {
    test('a file that was never written still needs both writes', () {
      final gate = MediaInfoWritebackGate();
      expect(gate.needsDuration('a', 1000), isTrue);
      expect(gate.needsDims('a', 1920, 1080), isTrue);
    });

    test('the SAME file is not written twice', () {
      final gate = MediaInfoWritebackGate();
      expect(gate.needsDuration('a', 1000), isTrue);
      gate.markDurationWritten('a');
      expect(gate.needsDuration('a', 1000), isFalse);

      expect(gate.needsDims('a', 1920, 1080), isTrue);
      gate.markDimsWritten('a');
      expect(gate.needsDims('a', 1920, 1080), isFalse);
    });

    test('a DIFFERENT file (the second of a session) needs its own writes', () {
      final gate = MediaInfoWritebackGate();
      gate.markDurationWritten('a');
      gate.markDimsWritten('a');

      expect(gate.needsDuration('b', 2000), isTrue);
      expect(gate.needsDims('b', 1280, 720), isTrue);
    });

    test('the two marks are independent', () {
      final gate = MediaInfoWritebackGate();
      // Duration arrived first, dimensions later, for the same file.
      gate.markDurationWritten('a');
      expect(gate.needsDims('a', 1920, 1080), isTrue);
      expect(gate.needsDuration('a', 1000), isFalse);
    });

    test('a zero/absent duration and a null/zero-size file write nothing', () {
      final gate = MediaInfoWritebackGate();
      expect(gate.needsDuration('a', 0), isFalse);
      expect(gate.needsDuration(null, 1000), isFalse);
      expect(gate.needsDims('a', 0, 1080), isFalse);
      expect(gate.needsDims('a', 1920, 0), isFalse);
      expect(gate.needsDims(null, 1920, 1080), isFalse);
    });

    test('re-playing a file after another one re-arms its write', () {
      final gate = MediaInfoWritebackGate();
      gate.markDurationWritten('a');
      gate.markDurationWritten('b');
      // A again: harmless to re-write, and it re-seeds the live progress store.
      expect(gate.needsDuration('a', 1000), isTrue);
    });

    test('a failed write releases the mark so the SAME file retries', () {
      final gate = MediaInfoWritebackGate();
      gate.markDurationWritten('a');
      gate.markDimsWritten('a');
      expect(gate.needsDuration('a', 1000), isFalse);

      // The write matched no `media_nodes` row (unscanned file, or a stored
      // path-shape mismatch): the mark must go, otherwise the duration/dims
      // backfill is dropped for good.
      gate.unmark('a');

      expect(gate.needsDuration('a', 1000), isTrue);
      expect(gate.needsDims('a', 1920, 1080), isTrue);
    });

    test('releasing a mark never clears the file that is CURRENT now', () {
      final gate = MediaInfoWritebackGate();
      gate.markDurationWritten('b');
      gate.markDimsWritten('b');

      // An in-flight write for the file the player has already left fails after
      // B started: B's own mark must survive.
      gate.unmark('a');

      expect(gate.needsDuration('b', 2000), isFalse);
      expect(gate.needsDims('b', 1280, 720), isFalse);
    });
  });
}
