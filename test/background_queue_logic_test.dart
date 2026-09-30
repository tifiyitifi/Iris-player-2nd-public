import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;

FileItem _f(String key) => FileItem(name: key, uri: 'file:///$key', path: [key]);

void main() {
  final a = _f('a');
  final b = _f('b');
  final c = _f('c');
  final list = [a, b, c];

  group('BackgroundQueueLogic.stepIndex', () {
    test('repeat all wraps forward and backward', () {
      expect(
        BackgroundQueueLogic.stepIndex(
            queue: list, current: 2, forward: true, repeat: Repeat.all),
        0,
      );
      expect(
        BackgroundQueueLogic.stepIndex(
            queue: list, current: 0, forward: false, repeat: Repeat.all),
        2,
      );
    });

    test('repeat none never wraps past the ends', () {
      expect(
        BackgroundQueueLogic.stepIndex(
            queue: list, current: 2, forward: true, repeat: Repeat.none),
        isNull,
      );
      expect(
        BackgroundQueueLogic.stepIndex(
            queue: list, current: 0, forward: false, repeat: Repeat.none),
        isNull,
      );
      expect(
        BackgroundQueueLogic.stepIndex(
            queue: list, current: 0, forward: true, repeat: Repeat.none),
        1,
      );
    });

    test('repeat none with an excluded candidate never wraps past an end', () {
      // [a,b,c], current b, forward: the only forward candidate is c; excluding
      // it must yield null, NOT wrap around to a.
      expect(
        BackgroundQueueLogic.stepIndex(
          queue: list,
          current: 1,
          forward: true,
          repeat: Repeat.none,
          excludedKey: backgroundMediaKey(c),
        ),
        isNull,
      );
      // Backward from b: only a is in range; excluding it is null, not a wrap.
      expect(
        BackgroundQueueLogic.stepIndex(
          queue: list,
          current: 1,
          forward: false,
          repeat: Repeat.none,
          excludedKey: backgroundMediaKey(a),
        ),
        isNull,
      );
      // A skipped candidate inside the range still steps within bounds.
      expect(
        BackgroundQueueLogic.stepIndex(
          queue: list,
          current: 0,
          forward: true,
          repeat: Repeat.none,
          excludedKey: backgroundMediaKey(b),
        ),
        2,
      );
    });

    test('repeat one returns the current index', () {
      expect(
        BackgroundQueueLogic.stepIndex(
            queue: list, current: 1, forward: true, repeat: Repeat.one),
        1,
      );
    });

    test('skips the excluded foreground-file key across the wrap', () {
      // Queue [a,b,c]; current c; forward with repeat all; excludedKey = a
      // must yield b (skip a after wrapping to 0).
      expect(
        BackgroundQueueLogic.stepIndex(
          queue: list,
          current: 2,
          forward: true,
          repeat: Repeat.all,
          excludedKey: backgroundMediaKey(a),
        ),
        1,
      );
    });

    test('null when every candidate is excluded or the queue is a lone '
        'foreground file', () {
      final alone = [a];
      expect(
        BackgroundQueueLogic.stepIndex(
          queue: alone,
          current: 0,
          forward: true,
          repeat: Repeat.all,
          excludedKey: backgroundMediaKey(a),
        ),
        isNull,
      );
      expect(BackgroundQueueLogic.stepIndex(
        queue: const [],
        current: -1,
        forward: true,
        repeat: Repeat.all,
      ), isNull);
    });
  });

  group('BackgroundQueueLogic.shuffle helpers', () {
    test('shuffled keeps all items and reorders deterministically per seed',
        () {
      final out = BackgroundQueueLogic.shuffled(list);
      expect(out.toSet(), list.toSet());
      // A raw dart:math shuffle can (rarely) keep the input order — assert the
      // reorder contract via a deterministic seed scan instead of luck.
      var reordered = false;
      for (var seed = 0; seed < 64; seed++) {
        final candidate =
            BackgroundQueueLogic.shuffled(list, random: Random(seed));
        if (candidate.join(',') != list.join(',')) {
          reordered = true;
          break;
        }
      }
      expect(reordered, isTrue, reason: 'some seed must change the order');
    });

    test('reshuffleKeepingCurrent anchors the current file at the head',
        () {
      final out = BackgroundQueueLogic.reshuffleKeepingCurrent(
        list,
        backgroundMediaKey(c),
        random: _FixedRandom(1),
      );
      expect(backgroundMediaKey(out.first), backgroundMediaKey(c));
      expect(out.toSet(), list.toSet());
    });

    test('reshuffle falls back to a plain shuffle without an anchor', () {
      final out = BackgroundQueueLogic.reshuffleKeepingCurrent(
        list,
        null,
        random: _FixedRandom(1),
      );
      expect(out.length, list.length);
    });
  });

  group('BackgroundQueueLogic.pickStartIndex', () {
    // The queue is the COMPLETE candidate pool (a video the user just tagged
    // belongs in it even while it is the foreground), so "where do we begin
    // playing" is a separate question from "what is in the list". This is the
    // one place that answers it, and every entry point funnels through it.
    int pick({
      required List<FileItem> queue,
      String? preferredKey,
      String? excludedKey,
    }) =>
        BackgroundQueueLogic.pickStartIndex(
          queue: queue,
          preferredKey: preferredKey,
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
  });
}

class _FixedRandom implements Random {
  _FixedRandom(this._seed);
  int _seed;

  @override
  bool nextBool() => _seed.isEven;

  @override
  double nextDouble() {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed / 0x7fffffff;
  }

  @override
  int nextInt(int max) {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed % max;
  }
}
