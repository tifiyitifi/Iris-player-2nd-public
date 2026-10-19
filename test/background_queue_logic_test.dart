import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/models/file.dart';

FileItem _f(String key) => FileItem(name: key, uri: 'file:///$key', path: [key]);

void main() {
  final a = _f('a');
  final b = _f('b');
  final c = _f('c');
  final list = [a, b, c];

  group('BackgroundQueueLogic.pickStartIndex', () {
    // The queue is the COMPLETE candidate pool (a video the user just tagged
    // belongs in it even while it is the foreground), so "where do we begin
    // playing" is a separate question from "what is in the list". This is the
    // one place that answers it, and every entry point funnels through it.
    int pick({
      required List<FileItem> queue,
      String? preferredKey,
      List<String> preferredKeys = const <String>[],
      String? excludedKey,
    }) =>
        BackgroundQueueLogic.pickStartIndex(
          queue: queue,
          preferredKeys: [
            if (preferredKey != null) preferredKey,
            ...preferredKeys,
          ],
          excludedKey: excludedKey,
        );

    test('keeps the preferred file when it can play', () {
      expect(
        pick(queue: list, preferredKey: backgroundMediaKey(c)),
        2,
      );
    });

    test('falls to the first playable entry when the preferred one is the '
        'foreground', () {
      // The file we want to keep playing IS the foreground right now, so it
      // cannot be the one we start on.
      expect(
        pick(
          queue: list,
          preferredKey: backgroundMediaKey(a),
          excludedKey: backgroundMediaKey(a),
        ),
        1,
      );
    });

    test('skips a leading foreground entry', () {
      expect(
        pick(queue: list, excludedKey: backgroundMediaKey(a)),
        1,
      );
    });

    test('keeps the head when everything is excluded', () {
      // Returning the head (rather than -1) mirrors `openGate`: a run whose
      // pool is entirely the foreground file keeps whatever is loaded instead
      // of going blank.
      final allForeground = [_f('a'), _f('b')];
      expect(
        pick(queue: allForeground, excludedKey: backgroundMediaKey(a)),
        1,
      );
      expect(
        pick(queue: [_f('a')], excludedKey: backgroundMediaKey(a)),
        0,
      );
    });

    test('a null excluded key disables the guard entirely', () {
      // `allowSameFgBgFile` lifts the guard, so the preferred entry wins even
      // though it equals the foreground.
      expect(
        pick(
          queue: list,
          preferredKey: backgroundMediaKey(a),
          excludedKey: null,
        ),
        0,
      );
    });

    test('falls back to the first playable when the preferred one is gone', () {
      expect(pick(queue: list, preferredKey: 'vanished'), 0);
    });

    test('an empty queue has no start index', () {
      expect(pick(queue: const []), -1);
    });

    test('matches on the media key, not file identity', () {
      // A re-resolved pool hands back fresh FileItem objects for the same
      // physical media; identity would fail here and lose the current file.
      final renamed = FileItem(name: 'renamed', uri: 'file:///c', path: ['c']);
      final rebuilt = [_f('a'), _f('b'), renamed];
      expect(
        pick(queue: rebuilt, preferredKey: backgroundMediaKey(c)),
        2,
      );
    });

    // ── preferredKeys: the ordered preference list ──

    test('the ordered preference list is walked in order', () {
      expect(
        pick(queue: list, preferredKeys: ['vanished', backgroundMediaKey(c)]),
        2,
      );
    });

    test('a remembered key that IS the foreground is skipped for the next '
        'preference (副音 never double-plays)', () {
      // The reported defect: the remembered occurrence was applied AFTER the
      // guard, so re-opening 副音 on the foreground's own file started the same
      // media on two engines. Both preferences are now filtered by the guard.
      expect(
        pick(
          queue: list,
          preferredKeys: [backgroundMediaKey(a), backgroundMediaKey(c)],
          excludedKey: backgroundMediaKey(a),
        ),
        2,
      );
    });

    test('an entirely excluded preference list falls through to the first '
        'playable entry', () {
      expect(
        pick(
          queue: list,
          preferredKeys: [backgroundMediaKey(a)],
          excludedKey: backgroundMediaKey(a),
        ),
        1,
      );
    });
  });
}
